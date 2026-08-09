//! Scanner-backed ext-image-copy-capture v1 frontend.

const Self = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const presentation = @import("../presentation.zig");
const render = @import("../render/types.zig");
const DmabufBuffer = @import("linux_dmabuf_buffer.zig");
const LinuxDmabuf = @import("linux_dmabuf.zig");
const Seat = @import("seat.zig");
const WayringCompositor = @import("WayringCompositor.zig");
const WayringImageCaptureSource = @import("WayringImageCaptureSource.zig");
const WayringLinuxDmabuf = @import("WayringLinuxDmabuf.zig");
const WayringSeatAdapter = @import("WayringSeatAdapter.zig");
const wl = @import("wayland").server.wl;

const server = wayring.server;
const Shm = server.shm.Protocol(protocol);

pub const Constraints = struct {
    size: render.Size,
    dmabuf_formats: [LinuxDmabuf.capture_formats.len]render.DmabufFormatModifier = @splat(.{
        .format = 0,
        .modifier = 0,
    }),
    dmabuf_format_count: usize = 0,

    fn dmabufFormats(self: *const Constraints) []const render.DmabufFormatModifier {
        return self.dmabuf_formats[0..self.dmabuf_format_count];
    }
};
pub const CursorTarget = struct {
    source: WayringImageCaptureSource.Target,
    seat: *Seat,
    pointer_object_id: u32,
    pointer_identity: WayringSeatAdapter.PointerIdentity,
};
pub const Target = union(enum) { source: WayringImageCaptureSource.Target, cursor: CursorTarget };
pub const CursorInfo = struct { entered: bool, position: render.Position, hotspot: render.Position };
pub const CaptureError = error{ Stopped, Failed };
pub const CaptureResult = struct { timestamp: presentation.Timestamp, completion_fd: ?std.posix.fd_t = null };
pub const Listener = struct {
    context: *anyopaque,
    constraints: *const fn (*anyopaque, Target) ?Constraints,
    schedule: *const fn (*anyopaque, Target, bool) ?@import("output_layout.zig").Id,
    capture_shm: *const fn (*anyopaque, Target, bool, render.PixelBuffer) CaptureError!CaptureResult,
    capture_dmabuf: *const fn (*anyopaque, Target, bool, *DmabufBuffer.Buffer) CaptureError!presentation.Timestamp,
    complete: *const fn (*anyopaque, render.PixelBuffer, ?render.PixelBuffer) bool,
    cursor_info: *const fn (*anyopaque, CursorTarget) ?CursorInfo,
};

const Manager = struct { owner: *Self, client: *server.Client, resource: protocol.ext_image_copy_capture_manager_v1.Resource };
const Session = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.ext_image_copy_capture_session_v1.Resource,
    target: ?Target,
    constraints: ?Constraints,
    paint_cursors: bool,
    frame: ?*Frame = null,
    stopped: bool = false,
    captured: bool = false,
};
const Destination = union(enum) {
    shm: server.shm.Buffer.Pin,
    dmabuf: *DmabufBuffer.Buffer,
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
    client: *server.Client,
    resource: protocol.ext_image_copy_capture_frame_v1.Resource,
    session: ?*Session,
    target: ?Target,
    constraints: ?Constraints,
    paint_cursors: bool,
    destination: ?Destination = null,
    requested: bool = false,
    finished: bool = false,
    scheduled_output: ?@import("output_layout.zig").Id = null,
    wait_for_damage: bool,
    pending: ?PendingCapture = null,
    const PendingCapture = struct {
        event_source: *wl.EventSource,
        completion_fd: std.posix.fd_t,
        pixels: render.PixelBuffer,
        constraints: Constraints,
        timestamp: presentation.Timestamp,
    };
};
const CursorSession = struct {
    owner: *Self,
    client: *server.Client,
    resource: protocol.ext_image_copy_capture_cursor_session_v1.Resource,
    target: ?CursorTarget,
    created: bool = false,
    entered: bool = false,
    position: ?render.Position = null,
    hotspot: ?render.Position = null,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
event_loop: *wl.EventLoop,
sources: *WayringImageCaptureSource,
seat_adapter: *WayringSeatAdapter,
seat: *Seat,
shm: *Shm,
dmabuf: ?*WayringLinuxDmabuf,
authorized_uid: std.os.linux.uid_t,
listener: Listener,
dmabuf_device: ?DmabufBuffer.Device,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
sessions: std.ArrayList(*Session) = .empty,
frames: std.ArrayList(*Frame) = .empty,
cursor_sessions: std.ArrayList(*CursorSession) = .empty,

pub fn init(self: *Self, allocator: std.mem.Allocator, protocol_server: *server.Server, event_loop: *wl.EventLoop, sources: *WayringImageCaptureSource, compositor: *WayringCompositor, dmabuf: ?*WayringLinuxDmabuf, seat_adapter: *WayringSeatAdapter, seat: *Seat, dmabuf_device: ?DmabufBuffer.Device, authorized_uid: std.os.linux.uid_t, listener: Listener) void {
    self.* = .{ .allocator = allocator, .protocol_server = protocol_server, .event_loop = event_loop, .sources = sources, .seat_adapter = seat_adapter, .seat = seat, .shm = compositor.shmAdapter(), .dmabuf = dmabuf, .dmabuf_device = dmabuf_device, .authorized_uid = authorized_uid, .listener = listener };
    sources.setInvalidationListener(.{ .context = self, .invalidated = sourceInvalidated });
    seat_adapter.setPointerResourceListener(.{ .context = self, .changed = pointerResourcesChanged });
}

pub fn publish(self: *Self) !void {
    self.global = try self.protocol_server.addGlobalWithOptions(protocol.ext_image_copy_capture_manager_v1, 1, Self, self, bind, .{ .visibility = .restricted });
}
pub fn unpublish(self: *Self) void {
    self.protocol_server.removeGlobal(self.global.?) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}
pub fn globalFilter(self: *const Self, client: *const server.Client, global: *const server.Server.Global) bool {
    return global.visibility() != .restricted or client.isAuthorizedDirectPeer(self.authorized_uid);
}
pub fn deinit(self: *Self) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.sessions.items.len == 0 and self.frames.items.len == 0 and self.cursor_sessions.items.len == 0);
    self.seat_adapter.clearPointerResourceListener(self);
    self.sources.clearInvalidationListener();
    self.cursor_sessions.deinit(self.allocator);
    self.frames.deinit(self.allocator);
    self.sessions.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}
pub fn destroyClientResources(self: *Self, client: *server.Client) void {
    var i = self.frames.items.len;
    while (i > 0) {
        i -= 1;
        if (self.frames.items[i].client == client) self.destroyFrame(self.frames.items[i]);
    }
    i = self.sessions.items.len;
    while (i > 0) {
        i -= 1;
        if (self.sessions.items[i].client == client) self.destroySession(self.sessions.items[i]);
    }
    i = self.cursor_sessions.items.len;
    while (i > 0) {
        i -= 1;
        if (self.cursor_sessions.items[i].client == client) self.destroyCursorSession(self.cursor_sessions.items[i]);
    }
    i = self.managers.items.len;
    while (i > 0) {
        i -= 1;
        if (self.managers.items[i].client == client) self.destroyManager(self.managers.items[i]);
    }
}
pub fn captureOutput(self: *Self, output: @import("output_layout.zig").Id) void {
    for (self.frames.items) |frame| if (frame.scheduled_output) |scheduled| if (std.meta.eql(output, scheduled)) capture(frame);
}
pub fn removeOutput(self: *Self, output: @import("output_layout.zig").Id) void {
    sourceInvalidated(self, .{ .output = output });
}
pub fn refreshCursors(self: *Self) void {
    for (self.cursor_sessions.items) |cursor| refreshCursor(cursor);
    for (self.sessions.items) |session| {
        const target = session.target orelse continue;
        if (target != .cursor or session.stopped) continue;
        if (!cursorTargetValid(self, session.client, target.cursor)) {
            stop(session);
            if (session.frame) |frame| fail(frame, .stopped);
            continue;
        }
        const current = constraintsForTarget(self, target) orelse continue;
        if (session.constraints == null or !std.meta.eql(session.constraints.?, current)) {
            session.constraints = current;
            sendConstraints(session);
        }
    }
}

fn bind(client: *server.Client, id: u32, version: u32, self: *Self) !void {
    if (version != 1) return error.InvalidVersion;
    if (!client.isAuthorizedDirectPeer(self.authorized_uid)) return error.Unauthorized;
    const value = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Manager, value, managerRequest, null);
    try client.materialize(&value.resource.runtime);
    try self.managers.append(self.allocator, value);
}
fn managerRequest(_: *protocol.ext_image_copy_capture_manager_v1.Resource, request: protocol.ext_image_copy_capture_manager_v1.Request, manager: *Manager) !void {
    if (!manager.client.isAuthorizedDirectPeer(manager.owner.authorized_uid)) return error.Unauthorized;
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .create_session => |args| {
            if (args.options & ~@as(u32, @intCast(protocol.ext_image_copy_capture_manager_v1.options.paint_cursors)) != 0) return manager.client.postProtocolError(&manager.resource.runtime, @intCast(protocol.ext_image_copy_capture_manager_v1.@"error".invalid_option), "invalid image capture option");
            const source = manager.owner.sources.targetForResource(manager.client, args.source);
            try manager.owner.createSession(manager.client, args.session, if (source) |target| .{ .source = target } else null, args.options != 0);
        },
        .create_pointer_cursor_session => |args| {
            const source = manager.owner.sources.targetForResource(manager.client, args.source);
            const identity = manager.owner.seat_adapter.pointerIdentity(manager.client, args.pointer);
            const target: ?CursorTarget = if (source) |s| if (identity) |p| .{ .source = s, .seat = manager.owner.seat, .pointer_object_id = args.pointer, .pointer_identity = p } else null else null;
            try manager.owner.createCursorSession(manager.client, args.session, target);
        },
    }
}
fn createSession(self: *Self, client: *server.Client, id: u32, target: ?Target, paint_cursors: bool) !void {
    const value = try self.allocator.create(Session);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, 1, .client, client.ownerHooks()), .target = target, .constraints = if (target) |t| constraintsForTarget(self, t) else null, .paint_cursors = paint_cursors };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Session, value, sessionRequest, null);
    try client.materialize(&value.resource.runtime);
    try self.sessions.append(self.allocator, value);
    if (target == null or value.constraints == null) stop(value) else sendConstraints(value);
}
fn sessionRequest(_: *protocol.ext_image_copy_capture_session_v1.Resource, request: protocol.ext_image_copy_capture_session_v1.Request, session: *Session) !void {
    if (!session.client.isAuthorizedDirectPeer(session.owner.authorized_uid)) return error.Unauthorized;
    switch (request) {
        .destroy => session.owner.destroySession(session),
        .create_frame => |args| {
            if (session.frame != null) return session.client.postProtocolError(&session.resource.runtime, @intCast(protocol.ext_image_copy_capture_session_v1.@"error".duplicate_frame), "capture frame already exists");
            try session.owner.createFrame(session, args.frame);
        },
    }
}
fn sendConstraints(session: *Session) void {
    const size = session.constraints.?.size;
    protocol.ext_image_copy_capture_session_v1.@"send:buffer_size"(&session.resource, size.width, size.height) catch |err| return eventFailed(session.client, &session.resource.runtime, err, "queueing image capture size");
    protocol.ext_image_copy_capture_session_v1.@"send:shm_format"(&session.resource, @intCast(protocol.wl_shm.format.argb8888)) catch |err| return eventFailed(session.client, &session.resource.runtime, err, "queueing image capture SHM format");
    protocol.ext_image_copy_capture_session_v1.@"send:shm_format"(&session.resource, @intCast(protocol.wl_shm.format.xrgb8888)) catch |err| return eventFailed(session.client, &session.resource.runtime, err, "queueing image capture SHM format");
    const dmabuf_formats = session.constraints.?.dmabufFormats();
    if (dmabuf_formats.len != 0) if (session.owner.dmabuf_device) |device| {
        protocol.ext_image_copy_capture_session_v1.@"send:dmabuf_device"(&session.resource, std.mem.asBytes(&device)) catch |err| return eventFailed(session.client, &session.resource.runtime, err, "queueing image capture DMA-BUF device");
        for (dmabuf_formats) |format| {
            const modifiers = [_]u64{format.modifier};
            protocol.ext_image_copy_capture_session_v1.@"send:dmabuf_format"(&session.resource, format.format, std.mem.asBytes(&modifiers)) catch |err| return eventFailed(session.client, &session.resource.runtime, err, "queueing image capture DMA-BUF format");
        }
    };
    protocol.ext_image_copy_capture_session_v1.@"send:done"(&session.resource) catch |err| eventFailed(session.client, &session.resource.runtime, err, "queueing image capture constraints completion");
}
fn stop(session: *Session) void {
    if (session.stopped) return;
    session.stopped = true;
    session.target = null;
    protocol.ext_image_copy_capture_session_v1.@"send:stopped"(&session.resource) catch |err| eventFailed(session.client, &session.resource.runtime, err, "queueing image capture stopped");
}
fn createFrame(self: *Self, session: *Session, id: u32) !void {
    const value = try self.allocator.create(Frame);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = session.client, .resource = .init(self.allocator, id, 1, .client, session.client.ownerHooks()), .session = session, .target = session.target, .constraints = session.constraints, .paint_cursors = session.paint_cursors, .wait_for_damage = session.captured };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(Frame, value, frameRequest, null);
    try session.client.materialize(&value.resource.runtime);
    try self.frames.append(self.allocator, value);
    session.frame = value;
    if (session.stopped) fail(value, .stopped);
}
fn frameRequest(_: *protocol.ext_image_copy_capture_frame_v1.Resource, request: protocol.ext_image_copy_capture_frame_v1.Request, frame: *Frame) !void {
    if (!frame.client.isAuthorizedDirectPeer(frame.owner.authorized_uid)) return error.Unauthorized;
    switch (request) {
        .destroy => frame.owner.destroyFrame(frame),
        .attach_buffer => |args| {
            if (frame.requested) return protocolError(frame, .already_captured, "capture already requested");
            if (!frame.finished) attach(frame, args.buffer);
        },
        .damage_buffer => |args| {
            if (frame.requested) return protocolError(frame, .already_captured, "capture already requested");
            if (args.x < 0 or args.y < 0 or args.width <= 0 or args.height <= 0) return protocolError(frame, .invalid_buffer_damage, "buffer damage must be positive");
        },
        .capture => {
            if (frame.requested) return protocolError(frame, .already_captured, "capture already requested");
            frame.requested = true;
            if (!frame.finished) requestCapture(frame);
        },
    }
}
fn attach(frame: *Frame, object_id: u32) void {
    releaseDestination(frame);
    const resource = frame.client.lookup(object_id) orelse return protocolError(frame, .no_buffer, "buffer is not live");
    frame.destination = if (frame.owner.shm.pin(resource)) |pin| .{ .shm = pin } else if (frame.owner.dmabuf) |adapter| if (adapter.captureBuffer(frame.client, object_id)) |buffer| .{ .dmabuf = buffer } else null else null;
    if (frame.destination == null) protocolError(frame, .no_buffer, "buffer is not generated SHM or DMA-BUF");
}
fn requestCapture(frame: *Frame) void {
    if (frame.destination == null) return protocolError(frame, .no_buffer, "capture requires a buffer");
    const target = frame.target orelse return fail(frame, .stopped);
    if (target == .cursor) {
        if (!cursorTargetValid(frame.owner, frame.client, target.cursor)) {
            fail(frame, .stopped);
            if (frame.session) |session| stop(session);
            return;
        }
        capture(frame);
        return;
    }
    frame.scheduled_output = frame.owner.listener.schedule(frame.owner.listener.context, target, frame.wait_for_damage) orelse {
        fail(frame, .stopped);
        if (frame.session) |s| stop(s);
        return;
    };
}
fn capture(frame: *Frame) void {
    if (frame.pending != null) return;
    frame.scheduled_output = null;
    const target = frame.target orelse return fail(frame, .stopped);
    if (target == .cursor and !cursorTargetValid(frame.owner, frame.client, target.cursor)) {
        fail(frame, .stopped);
        if (frame.session) |session| stop(session);
        return;
    }
    const expected = frame.constraints orelse return fail(frame, .stopped);
    const current = constraintsForTarget(frame.owner, target) orelse {
        fail(frame, .stopped);
        if (frame.session) |s| stop(s);
        return;
    };
    if (!std.meta.eql(current, expected)) {
        if (frame.session) |s| {
            s.constraints = current;
            sendConstraints(s);
        }
        return fail(frame, .buffer_constraints);
    }
    const timestamp = switch (frame.destination.?) {
        .shm => captureShm(frame, &frame.destination.?.shm, target, expected.size) orelse return,
        .dmabuf => |buffer| blk: {
            if (!std.meta.eql(buffer.descriptor.size, expected.size)) return fail(frame, .buffer_constraints);
            if (!bufferCaptureCompatible(buffer, expected)) return fail(frame, .buffer_constraints);
            break :blk frame.owner.listener.capture_dmabuf(frame.owner.listener.context, target, frame.paint_cursors, buffer) catch |err| {
                if (err == error.Stopped) {
                    fail(frame, .stopped);
                    if (frame.session) |s| stop(s);
                } else fail(frame, .unknown);
                return;
            };
        },
    };
    ready(frame, expected, timestamp);
}
fn captureShm(frame: *Frame, pin: *server.shm.Buffer.Pin, target: Target, size: render.Size) ?presentation.Timestamp {
    var access = pin.access() catch {
        fail(frame, .unknown);
        return null;
    };
    const pixels = shmPixelBuffer(access.geometry, access.bytes, size) orelse {
        _ = access.end() catch {};
        fail(frame, .buffer_constraints);
        return null;
    };
    const captured = frame.owner.listener.capture_shm(frame.owner.listener.context, target, frame.paint_cursors, pixels) catch |err| {
        _ = access.end() catch {};
        if (err == error.Stopped) {
            fail(frame, .stopped);
            if (frame.session) |s| stop(s);
        } else fail(frame, .unknown);
        return null;
    };
    if (captured.completion_fd) |fd| {
        startPendingCapture(frame, pixels, frame.constraints.?, captured) catch {
            _ = std.c.close(fd);
            const succeeded = frame.owner.listener.complete(frame.owner.listener.context, pixels, pixels);
            access.end() catch {
                fail(frame, .unknown);
                return null;
            };
            if (!succeeded) fail(frame, .unknown);
            return if (succeeded) captured.timestamp else null;
        };
        access.end() catch {
            cancelPendingCapture(frame);
            fail(frame, .unknown);
        };
        return null;
    }
    access.end() catch {
        fail(frame, .unknown);
        return null;
    };
    return captured.timestamp;
}
fn ready(frame: *Frame, constraints: Constraints, timestamp: presentation.Timestamp) void {
    frame.finished = true;
    if (frame.session) |s| s.captured = true;
    defer releaseDestination(frame);
    protocol.ext_image_copy_capture_frame_v1.@"send:transform"(&frame.resource, @intCast(protocol.wl_output.transform.normal)) catch |err| return eventFailed(frame.client, &frame.resource.runtime, err, "queueing image capture transform");
    protocol.ext_image_copy_capture_frame_v1.@"send:damage"(&frame.resource, 0, 0, @intCast(constraints.size.width), @intCast(constraints.size.height)) catch |err| return eventFailed(frame.client, &frame.resource.runtime, err, "queueing image capture damage");
    protocol.ext_image_copy_capture_frame_v1.@"send:presentation_time"(&frame.resource, timestamp.highSeconds(), timestamp.lowSeconds(), timestamp.nanoseconds) catch |err| return eventFailed(frame.client, &frame.resource.runtime, err, "queueing image capture timestamp");
    protocol.ext_image_copy_capture_frame_v1.@"send:ready"(&frame.resource) catch |err| return eventFailed(frame.client, &frame.resource.runtime, err, "queueing image capture ready");
}
fn fail(frame: *Frame, reason: @TypeOf(.enum_literal)) void {
    if (frame.finished) return;
    frame.finished = true;
    frame.scheduled_output = null;
    cancelPendingCapture(frame);
    protocol.ext_image_copy_capture_frame_v1.@"send:failed"(&frame.resource, @intCast(@field(protocol.ext_image_copy_capture_frame_v1.failure_reason, @tagName(reason)))) catch |err| eventFailed(frame.client, &frame.resource.runtime, err, "queueing image capture failure");
    releaseDestination(frame);
}
fn protocolError(frame: *Frame, reason: @TypeOf(.enum_literal), detail: []const u8) void {
    frame.client.postProtocolError(&frame.resource.runtime, @intCast(@field(protocol.ext_image_copy_capture_frame_v1.@"error", @tagName(reason))), detail);
}
fn createCursorSession(self: *Self, client: *server.Client, id: u32, target: ?CursorTarget) !void {
    const value = try self.allocator.create(CursorSession);
    errdefer self.allocator.destroy(value);
    value.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, 1, .client, client.ownerHooks()), .target = target };
    errdefer {
        value.resource.destroy();
        value.resource.deinit();
    }
    try value.resource.setHandler(CursorSession, value, cursorRequest, null);
    try client.materialize(&value.resource.runtime);
    try self.cursor_sessions.append(self.allocator, value);
    refreshCursor(value);
}
fn cursorRequest(_: *protocol.ext_image_copy_capture_cursor_session_v1.Resource, request: protocol.ext_image_copy_capture_cursor_session_v1.Request, cursor: *CursorSession) !void {
    if (!cursor.client.isAuthorizedDirectPeer(cursor.owner.authorized_uid)) return error.Unauthorized;
    switch (request) {
        .destroy => cursor.owner.destroyCursorSession(cursor),
        .get_capture_session => |args| {
            if (cursor.created) return cursor.client.postProtocolError(&cursor.resource.runtime, @intCast(protocol.ext_image_copy_capture_cursor_session_v1.@"error".duplicate_session), "cursor capture session already exists");
            cursor.created = true;
            try cursor.owner.createSession(cursor.client, args.session, if (cursor.target) |target| .{ .cursor = target } else null, false);
        },
    }
}
fn sourceForTarget(target: Target) WayringImageCaptureSource.Target {
    return switch (target) {
        .source => |source| source,
        .cursor => |cursor| cursor.source,
    };
}
fn refreshCursor(cursor: *CursorSession) void {
    if (cursor.target) |target| {
        if (!cursorTargetValid(cursor.owner, cursor.client, target)) invalidateCursor(cursor);
    }
    const info = if (cursor.target) |target| cursor.owner.listener.cursor_info(cursor.owner.listener.context, target) else null;
    const entered = if (info) |value| value.entered else false;
    if (entered and !cursor.entered) protocol.ext_image_copy_capture_cursor_session_v1.@"send:enter"(&cursor.resource) catch |err| eventFailed(cursor.client, &cursor.resource.runtime, err, "queueing cursor enter");
    if (!entered and cursor.entered) protocol.ext_image_copy_capture_cursor_session_v1.@"send:leave"(&cursor.resource) catch |err| eventFailed(cursor.client, &cursor.resource.runtime, err, "queueing cursor leave");
    if (!entered) {
        cursor.entered = false;
        cursor.position = null;
        cursor.hotspot = null;
        return;
    }
    const value = info.?;
    if (cursor.position == null or !std.meta.eql(cursor.position.?, value.position)) protocol.ext_image_copy_capture_cursor_session_v1.@"send:position"(&cursor.resource, value.position.x, value.position.y) catch |err| eventFailed(cursor.client, &cursor.resource.runtime, err, "queueing cursor position");
    if (cursor.hotspot == null or !std.meta.eql(cursor.hotspot.?, value.hotspot)) protocol.ext_image_copy_capture_cursor_session_v1.@"send:hotspot"(&cursor.resource, value.hotspot.x, value.hotspot.y) catch |err| eventFailed(cursor.client, &cursor.resource.runtime, err, "queueing cursor hotspot");
    cursor.entered = true;
    cursor.position = value.position;
    cursor.hotspot = value.hotspot;
}
fn invalidateCursor(cursor: *CursorSession) void {
    if (cursor.entered) protocol.ext_image_copy_capture_cursor_session_v1.@"send:leave"(&cursor.resource) catch |err| eventFailed(cursor.client, &cursor.resource.runtime, err, "queueing cursor leave");
    cursor.target = null;
    cursor.entered = false;
    cursor.position = null;
    cursor.hotspot = null;
}

fn shmPixelBuffer(geometry: anytype, bytes: []u8, expected: render.Size) ?render.PixelBuffer {
    if (geometry.width != expected.width or geometry.height != expected.height or geometry.stride == 0 or
        @mod(geometry.stride, @sizeOf(u32)) != 0 or
        (geometry.format != .argb8888 and geometry.format != .xrgb8888) or
        @intFromPtr(bytes.ptr) % @alignOf(u32) != 0) return null;
    const stride_pixels: u32 = @intCast(geometry.stride / @sizeOf(u32));
    if (stride_pixels < expected.width) return null;
    const row_offset = std.math.mul(usize, expected.height - 1, stride_pixels) catch return null;
    const required_pixels = std.math.add(usize, row_offset, expected.width) catch return null;
    if (required_pixels > bytes.len / @sizeOf(u32)) return null;
    return .{ .size = expected, .stride_pixels = stride_pixels, .pixels = @alignCast(std.mem.bytesAsSlice(u32, bytes)[0..required_pixels]) };
}
fn bufferCaptureCompatible(buffer: *DmabufBuffer.Buffer, constraints: Constraints) bool {
    const descriptor = buffer.descriptor;
    if (!std.meta.eql(descriptor.size, constraints.size) or descriptor.y_inverted or descriptor.plane_count != 1) return false;
    return render.DmabufFormatModifier.contains(
        constraints.dmabufFormats(),
        descriptor.format,
        descriptor.modifier,
    );
}

fn constraintsForTarget(self: *Self, target: Target) ?Constraints {
    var constraints = self.listener.constraints(self.listener.context, target) orelse return null;
    if (self.dmabuf == null or self.dmabuf_device == null) {
        constraints.dmabuf_format_count = 0;
        return constraints;
    }
    var count: usize = 0;
    for (constraints.dmabufFormats()) |format| {
        if (!self.dmabuf.?.supportsPair(format.format, format.modifier)) continue;
        constraints.dmabuf_formats[count] = format;
        count += 1;
    }
    constraints.dmabuf_format_count = count;
    return constraints;
}

fn cursorTargetValid(self: *Self, client: *server.Client, target: CursorTarget) bool {
    const current = self.seat_adapter.pointerIdentity(client, target.pointer_object_id) orelse return false;
    return std.meta.eql(current, target.pointer_identity);
}

fn pointerResourcesChanged(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.refreshCursors();
}
fn startPendingCapture(frame: *Frame, pixels: render.PixelBuffer, constraints: Constraints, captured: CaptureResult) !void {
    const fd = captured.completion_fd orelse unreachable;
    frame.pending = .{ .event_source = undefined, .completion_fd = fd, .pixels = pixels, .constraints = constraints, .timestamp = captured.timestamp };
    errdefer frame.pending = null;
    frame.pending.?.event_source = try frame.owner.event_loop.addFd(*Frame, fd, .{ .readable = true, .hangup = true, .@"error" = true }, captureReady, frame);
}
fn captureReady(_: c_int, _: wl.EventMask, frame: *Frame) c_int {
    completePendingCapture(frame, true);
    return 0;
}
fn cancelPendingCapture(frame: *Frame) void {
    if (frame.pending != null) completePendingCapture(frame, false);
}
fn completePendingCapture(frame: *Frame, send_result: bool) void {
    const pending = frame.pending orelse return;
    frame.pending = null;
    pending.event_source.remove();
    _ = std.c.close(pending.completion_fd);
    const pin = switch (frame.destination orelse {
        _ = frame.owner.listener.complete(frame.owner.listener.context, pending.pixels, null);
        return;
    }) {
        .shm => |*value| value,
        else => unreachable,
    };
    var access = pin.access() catch {
        _ = frame.owner.listener.complete(frame.owner.listener.context, pending.pixels, null);
        if (send_result) fail(frame, .unknown);
        return;
    };
    const destination = shmPixelBuffer(access.geometry, access.bytes, pending.pixels.size);
    const succeeded = frame.owner.listener.complete(frame.owner.listener.context, pending.pixels, destination);
    access.end() catch {
        if (send_result) fail(frame, .unknown);
        return;
    };
    if (!send_result) return;
    if (succeeded) ready(frame, pending.constraints, pending.timestamp) else fail(frame, .unknown);
}
fn sourceInvalidated(context: *anyopaque, target: WayringImageCaptureSource.Target) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.sessions.items) |session| if (session.target) |current| if (std.meta.eql(sourceForTarget(current), target)) stop(session);
    for (self.frames.items) |frame| if (frame.target) |current| if (std.meta.eql(sourceForTarget(current), target)) fail(frame, .stopped);
    for (self.cursor_sessions.items) |cursor| if (cursor.target) |current| if (std.meta.eql(current.source, target)) invalidateCursor(cursor);
}
fn releaseDestination(frame: *Frame) void {
    if (frame.destination) |*destination| destination.release();
    frame.destination = null;
}
fn destroyFrame(self: *Self, value: *Frame) void {
    cancelPendingCapture(value);
    remove(Frame, &self.frames, value);
    if (value.session) |s| s.frame = null;
    releaseDestination(value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroySession(self: *Self, value: *Session) void {
    remove(Session, &self.sessions, value);
    if (value.frame) |f| f.session = null;
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyCursorSession(self: *Self, value: *CursorSession) void {
    remove(CursorSession, &self.cursor_sessions, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn destroyManager(self: *Self, value: *Manager) void {
    remove(Manager, &self.managers, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}
fn remove(comptime T: type, list: *std.ArrayList(*T), value: *T) void {
    for (list.items, 0..) |candidate, index| if (candidate == value) {
        _ = list.swapRemove(index);
        return;
    };
    unreachable;
}
fn eventFailed(client: *server.Client, resource: *server.Resource, err: anyerror, detail: []const u8) void {
    switch (err) {
        error.OutOfMemory, error.WriteFailed, error.DuplicateFileDescriptor => client.postOutOfMemory(resource, detail),
        error.OutputSealed, error.ClientFatal, error.ResourceNotLive => {},
        else => client.postImplementationError(resource, detail),
    }
}

test "generated image copy capture descriptors are exact" {
    try std.testing.expectEqual(@as(u32, 1), protocol.ext_image_copy_capture_manager_v1.interface.version);
    try std.testing.expectEqual(@as(usize, 3), protocol.ext_image_copy_capture_manager_v1.request_messages.len);
    try std.testing.expectEqualStrings("create_session", protocol.ext_image_copy_capture_manager_v1.request_messages[0].name);
    try std.testing.expectEqual(@as(usize, 6), protocol.ext_image_copy_capture_frame_v1.event_messages.len);
    try std.testing.expectEqual(@as(i64, 3), protocol.ext_image_copy_capture_frame_v1.@"error".already_captured);
}

test "generated image copy capture accepts padded SHM stride exactly" {
    var storage: [8]u32 align(@alignOf(u32)) = @splat(0);
    const pixels = shmPixelBuffer(.{
        .width = 2,
        .height = 2,
        .stride = 16,
        .format = .argb8888,
    }, std.mem.sliceAsBytes(&storage), .{ .width = 2, .height = 2 }).?;
    try std.testing.expectEqual(@as(u32, 4), pixels.stride_pixels);
    try std.testing.expectEqual(@as(usize, 6), pixels.pixels.len);
    try std.testing.expect(shmPixelBuffer(.{
        .width = 2,
        .height = 2,
        .stride = 4,
        .format = .argb8888,
    }, std.mem.sliceAsBytes(&storage), .{ .width = 2, .height = 2 }) == null);
}
