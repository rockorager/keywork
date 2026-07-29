//! Privileged image capture into client-provided buffers.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const presentation = @import("../presentation.zig");
const render = @import("../render/types.zig");
const ImageCaptureSource = @import("image_capture_source.zig");
const LinuxDmabuf = @import("linux_dmabuf.zig");
const OutputLayout = @import("output_layout.zig");
const SecurityContext = @import("security_context.zig");
const Seat = @import("seat.zig");

const wl = wayland.server.wl;
const ext = wayland.server.ext;

allocator: std.mem.Allocator,
global: *wl.Global,
event_loop: *wl.EventLoop,
security_context: *SecurityContext,
sources: *ImageCaptureSource,
linux_dmabuf: *LinuxDmabuf,
listener: Listener,
sessions: std.ArrayList(*Session),
frames: std.ArrayList(*Frame),
cursor_sessions: std.ArrayList(*CursorSession),

pub const Constraints = struct {
    size: render.Size,
    transform: wl.Output.Transform = .normal,
};

pub const CursorTarget = struct {
    source: ImageCaptureSource.Target,
    seat: *Seat,
};

pub const Target = union(enum) {
    source: ImageCaptureSource.Target,
    cursor: CursorTarget,
};

pub const CursorInfo = struct {
    entered: bool,
    position: render.Position,
    hotspot: render.Position,
};

pub const CaptureError = error{ Stopped, Failed };

pub const CaptureResult = struct {
    timestamp: presentation.Timestamp,
    /// Owned by the caller when non-null.
    completion_fd: ?std.posix.fd_t = null,
};

pub const Listener = struct {
    context: *anyopaque,
    constraints: *const fn (*anyopaque, Target) ?Constraints,
    schedule: *const fn (*anyopaque, Target, bool) ?OutputLayout.Id,
    capture: *const fn (
        *anyopaque,
        Target,
        bool,
        render.PixelBuffer,
    ) CaptureError!CaptureResult,
    capture_dmabuf: *const fn (
        *anyopaque,
        Target,
        bool,
        *LinuxDmabuf.Buffer,
    ) CaptureError!presentation.Timestamp,
    complete: *const fn (*anyopaque, render.PixelBuffer, ?render.PixelBuffer) bool,
    cursor_info: *const fn (*anyopaque, CursorTarget) ?CursorInfo,
};

const Destination = struct {
    resource: ?*wl.Buffer = null,
    shm: ?*wl.shm.Buffer = null,
    dmabuf: ?*LinuxDmabuf.Buffer = null,
    destroy_listener: wl.Listener(*wl.Resource) = undefined,

    fn set(self: *Destination, resource: *wl.Buffer) void {
        self.clear();
        const shm = wl.shm.Buffer.get(@ptrCast(resource));
        const dmabuf = if (shm == null) LinuxDmabuf.Buffer.fromResource(resource) else null;
        self.resource = resource;
        self.shm = if (shm) |buffer| wl_shm_buffer_ref(buffer) else null;
        self.dmabuf = dmabuf;
        if (dmabuf) |buffer| buffer.reference();
        self.destroy_listener = wl.Listener(*wl.Resource).init(handleResourceDestroy);
        @as(*wl.Resource, @ptrCast(resource)).addDestroyListener(&self.destroy_listener);
    }

    fn clear(self: *Destination) void {
        if (self.resource != null) self.destroy_listener.link.remove();
        if (self.shm) |buffer| wl_shm_buffer_unref(buffer);
        if (self.dmabuf) |buffer| buffer.unreference();
        self.resource = null;
        self.shm = null;
        self.dmabuf = null;
    }

    fn attached(self: *const Destination) bool {
        return self.shm != null or self.dmabuf != null;
    }

    fn handleResourceDestroy(
        listener: *wl.Listener(*wl.Resource),
        _: *wl.Resource,
    ) void {
        const self: *Destination = @fieldParentPtr("destroy_listener", listener);
        listener.link.remove();
        self.resource = null;
    }
};

const Session = struct {
    owner: *Self,
    resource: *ext.ImageCopyCaptureSessionV1,
    target: ?Target,
    constraints: ?Constraints,
    frame: ?*Frame = null,
    paint_cursors: bool,
    stopped: bool = false,
    captured: bool = false,

    fn create(
        owner: *Self,
        client: *wl.Client,
        id: u32,
        target: ?Target,
        paint_cursors: bool,
    ) !void {
        const resource = try ext.ImageCopyCaptureSessionV1.create(client, 1, id);
        errdefer resource.destroy();
        const self = try owner.allocator.create(Session);
        errdefer owner.allocator.destroy(self);
        const constraints = if (target) |value| owner.listener.constraints(
            owner.listener.context,
            value,
        ) else null;
        self.* = .{
            .owner = owner,
            .resource = resource,
            .target = target,
            .constraints = constraints,
            .paint_cursors = paint_cursors,
        };
        try owner.sessions.append(owner.allocator, self);
        resource.setHandler(*Session, handleRequest, handleDestroy, self);
        if (target == null) {
            self.stop();
        } else if (constraints) |value| {
            self.sendConstraints(value);
        } else if (target.? == .source) {
            self.stop();
        }
    }

    fn handleRequest(
        resource: *ext.ImageCopyCaptureSessionV1,
        request: ext.ImageCopyCaptureSessionV1.Request,
        self: *Session,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .create_frame => |create_frame| {
                if (self.frame != null) {
                    resource.postError(.duplicate_frame, "a capture frame already exists");
                    return;
                }
                Frame.create(self, create_frame.frame) catch resource.postNoMemory();
            },
        }
    }

    fn handleDestroy(_: *ext.ImageCopyCaptureSessionV1, self: *Session) void {
        if (self.frame) |frame| frame.session = null;
        for (self.owner.sessions.items, 0..) |session, index| {
            if (session != self) continue;
            _ = self.owner.sessions.swapRemove(index);
            break;
        }
        self.owner.allocator.destroy(self);
    }

    fn sendConstraints(self: *Session, constraints: Constraints) void {
        self.resource.sendBufferSize(constraints.size.width, constraints.size.height);
        self.resource.sendShmFormat(.argb8888);
        self.resource.sendShmFormat(.xrgb8888);
        if (self.owner.linux_dmabuf.allocationDevice()) |device_value| {
            var device = device_value;
            var device_array: wl.Array = .{
                .size = @sizeOf(LinuxDmabuf.Device),
                .alloc = @sizeOf(LinuxDmabuf.Device),
                .data = @ptrCast(&device),
            };
            self.resource.sendDmabufDevice(&device_array);
            for (LinuxDmabuf.capture_formats) |format| {
                var modifiers = [_]u64{format.modifier};
                var modifier_array: wl.Array = .{
                    .size = @sizeOf(@TypeOf(modifiers)),
                    .alloc = @sizeOf(@TypeOf(modifiers)),
                    .data = @ptrCast(&modifiers),
                };
                self.resource.sendDmabufFormat(format.format, &modifier_array);
            }
        }
        self.resource.sendDone();
    }

    fn refreshCursorConstraints(self: *Session) void {
        if (self.stopped) return;
        const target = self.target orelse return;
        if (target != .cursor) return;
        const current = self.owner.listener.constraints(
            self.owner.listener.context,
            target,
        ) orelse return;
        if (self.constraints) |previous| {
            if (std.meta.eql(previous, current)) return;
        }
        self.constraints = current;
        self.sendConstraints(current);
    }

    fn stop(self: *Session) void {
        if (self.stopped) return;
        self.stopped = true;
        self.target = null;
        self.resource.sendStopped();
    }
};

const Frame = struct {
    owner: *Self,
    resource: *ext.ImageCopyCaptureFrameV1,
    session: ?*Session,
    target: ?Target,
    constraints: ?Constraints,
    paint_cursors: bool,
    destination: Destination = .{},
    capture_requested: bool = false,
    finished: bool = false,
    scheduled_output: ?OutputLayout.Id = null,
    wait_for_damage: bool,
    pending: ?PendingCapture = null,

    const PendingCapture = struct {
        event_source: *wl.EventSource,
        completion_fd: std.posix.fd_t,
        shm: *wl.shm.Buffer,
        pixels: render.PixelBuffer,
        constraints: Constraints,
        timestamp: presentation.Timestamp,
    };

    fn create(session: *Session, id: u32) !void {
        const resource = try ext.ImageCopyCaptureFrameV1.create(
            session.resource.getClient(),
            1,
            id,
        );
        errdefer resource.destroy();
        const self = try session.owner.allocator.create(Frame);
        errdefer session.owner.allocator.destroy(self);
        self.* = .{
            .owner = session.owner,
            .resource = resource,
            .session = session,
            .target = session.target,
            .constraints = session.constraints,
            .paint_cursors = session.paint_cursors,
            .wait_for_damage = session.captured,
        };
        try session.owner.frames.append(session.owner.allocator, self);
        session.frame = self;
        resource.setHandler(*Frame, handleRequest, handleDestroy, self);
        if (session.stopped) self.fail(.stopped);
    }

    fn handleRequest(
        resource: *ext.ImageCopyCaptureFrameV1,
        request: ext.ImageCopyCaptureFrameV1.Request,
        self: *Frame,
    ) void {
        if (request == .destroy) {
            resource.destroy();
            return;
        }
        switch (request) {
            .destroy => unreachable,
            .attach_buffer => |attach| {
                if (self.capture_requested) {
                    resource.postError(.already_captured, "the capture request was already sent");
                    return;
                }
                if (!self.finished) self.destination.set(attach.buffer);
            },
            .damage_buffer => |damage| {
                if (self.capture_requested) {
                    resource.postError(.already_captured, "the capture request was already sent");
                    return;
                }
                if (self.finished) return;
                if (damage.x < 0 or damage.y < 0 or damage.width <= 0 or damage.height <= 0) {
                    resource.postError(.invalid_buffer_damage, "buffer damage must be positive");
                    return;
                }
                // The whole destination is copied, so client damage is only a hint.
            },
            .capture => {
                if (self.capture_requested) {
                    resource.postError(.already_captured, "the capture request was already sent");
                    return;
                }
                self.capture_requested = true;
                if (!self.finished) self.requestCapture();
            },
        }
    }

    fn handleDestroy(_: *ext.ImageCopyCaptureFrameV1, self: *Frame) void {
        self.cancelPendingCapture();
        if (self.session) |session| session.frame = null;
        for (self.owner.frames.items, 0..) |frame, index| {
            if (frame != self) continue;
            _ = self.owner.frames.swapRemove(index);
            break;
        }
        self.destination.clear();
        self.owner.allocator.destroy(self);
    }

    fn requestCapture(self: *Frame) void {
        if (!self.destination.attached()) {
            self.resource.postError(.no_buffer, "capture requires an attached buffer");
            return;
        }
        const target = self.target orelse return self.fail(.stopped);
        switch (target) {
            .source => {
                self.scheduled_output = self.owner.listener.schedule(
                    self.owner.listener.context,
                    target,
                    self.wait_for_damage,
                ) orelse {
                    self.fail(.stopped);
                    self.stopSession();
                    return;
                };
            },
            .cursor => self.capture(),
        }
    }

    fn capture(self: *Frame) void {
        if (self.pending != null) return;
        self.scheduled_output = null;
        if (!self.destination.attached()) {
            self.resource.postError(.no_buffer, "capture requires an attached buffer");
            return;
        }
        const target = self.target orelse return self.fail(.stopped);
        const expected = self.constraints orelse return switch (target) {
            .source => self.fail(.stopped),
            .cursor => self.fail(.unknown),
        };
        const current = self.owner.listener.constraints(self.owner.listener.context, target) orelse
            return switch (target) {
                .source => {
                    self.fail(.stopped);
                    self.stopSession();
                },
                .cursor => self.fail(.unknown),
            };
        if (!std.meta.eql(current, expected)) {
            if (self.session) |session| {
                if (!session.stopped) {
                    session.constraints = current;
                    session.sendConstraints(current);
                }
            }
            return self.fail(.buffer_constraints);
        }
        if (self.destination.shm) |shm| {
            shm.beginAccess();
            const pixel_buffer = shmPixelBuffer(shm, expected.size) orelse {
                shm.endAccess();
                return self.fail(.buffer_constraints);
            };
            const captured = self.performCapture(target, pixel_buffer) orelse {
                shm.endAccess();
                return;
            };
            if (captured.completion_fd) |fd| {
                self.startPendingCapture(shm, pixel_buffer, expected, captured) catch {
                    _ = std.c.close(fd);
                    const completed = self.owner.listener.complete(
                        self.owner.listener.context,
                        pixel_buffer,
                        pixel_buffer,
                    );
                    shm.endAccess();
                    if (!completed) return self.fail(.unknown);
                    return self.ready(expected, captured.timestamp);
                };
                // The GPU writes staging memory. Re-enter SHM access only for
                // the completion copy so other pools remain usable.
                shm.endAccess();
                return;
            }
            shm.endAccess();
            return self.ready(expected, captured.timestamp);
        } else if (self.destination.dmabuf) |dmabuf| {
            if (self.owner.linux_dmabuf.allocationDevice() == null or
                !std.meta.eql(dmabuf.size(), expected.size) or
                !dmabuf.isCaptureCompatible()) return self.fail(.buffer_constraints);
            const timestamp = self.owner.listener.capture_dmabuf(
                self.owner.listener.context,
                target,
                self.paint_cursors,
                dmabuf,
            ) catch |err| switch (err) {
                error.Stopped => {
                    self.fail(.stopped);
                    self.stopSession();
                    return;
                },
                error.Failed => null,
            };
            if (timestamp) |value| return self.ready(expected, value);

            const pixel_count = expected.size.pixelCount() catch
                return self.fail(.buffer_constraints);
            const pixels = self.owner.allocator.alloc(u32, pixel_count) catch {
                self.resource.postNoMemory();
                return;
            };
            defer self.owner.allocator.free(pixels);
            const pixel_buffer: render.PixelBuffer = .{
                .size = expected.size,
                .stride_pixels = expected.size.width,
                .pixels = pixels,
            };
            const captured = self.performCapture(target, pixel_buffer) orelse return;
            if (captured.completion_fd) |fd| {
                defer _ = std.c.close(fd);
                if (!self.owner.listener.complete(
                    self.owner.listener.context,
                    pixel_buffer,
                    pixel_buffer,
                )) return self.fail(.unknown);
            }
            dmabuf.copyFromPixels(pixel_buffer) catch return self.fail(.unknown);
            return self.ready(expected, captured.timestamp);
        } else return self.fail(.buffer_constraints);
    }

    fn performCapture(
        self: *Frame,
        target: Target,
        pixel_buffer: render.PixelBuffer,
    ) ?CaptureResult {
        return self.owner.listener.capture(
            self.owner.listener.context,
            target,
            self.paint_cursors,
            pixel_buffer,
        ) catch |err| switch (err) {
            error.Stopped => {
                self.fail(.stopped);
                self.stopSession();
                return null;
            },
            error.Failed => {
                self.fail(.unknown);
                return null;
            },
        };
    }

    fn startPendingCapture(
        self: *Frame,
        shm: *wl.shm.Buffer,
        pixels: render.PixelBuffer,
        constraints: Constraints,
        captured: CaptureResult,
    ) !void {
        const completion_fd = captured.completion_fd orelse unreachable;
        std.debug.assert(self.pending == null);
        self.pending = .{
            .event_source = undefined,
            .completion_fd = completion_fd,
            .shm = shm,
            .pixels = pixels,
            .constraints = constraints,
            .timestamp = captured.timestamp,
        };
        errdefer self.pending = null;
        self.pending.?.event_source = try self.owner.event_loop.addFd(
            *Frame,
            completion_fd,
            .{ .readable = true, .hangup = true, .@"error" = true },
            handleCaptureReady,
            self,
        );
    }

    fn handleCaptureReady(_: c_int, _: wl.EventMask, self: *Frame) c_int {
        self.completePendingCapture(true);
        return 0;
    }

    fn cancelPendingCapture(self: *Frame) void {
        if (self.pending != null) self.completePendingCapture(false);
    }

    fn completePendingCapture(self: *Frame, send_result: bool) void {
        const pending = self.pending orelse return;
        self.pending = null;
        pending.event_source.remove();
        _ = std.c.close(pending.completion_fd);
        pending.shm.beginAccess();
        const destination = shmPixelBuffer(pending.shm, pending.pixels.size);
        const succeeded = self.owner.listener.complete(
            self.owner.listener.context,
            pending.pixels,
            destination,
        );
        pending.shm.endAccess();
        if (!send_result) return;
        if (succeeded) {
            self.ready(pending.constraints, pending.timestamp);
        } else {
            self.fail(.unknown);
        }
    }

    fn ready(
        self: *Frame,
        expected: Constraints,
        timestamp: presentation.Timestamp,
    ) void {
        std.debug.assert(!self.finished);
        std.debug.assert(self.scheduled_output == null);
        std.debug.assert(self.pending == null);
        self.resource.sendTransform(expected.transform);
        self.resource.sendDamage(
            0,
            0,
            @intCast(expected.size.width),
            @intCast(expected.size.height),
        );
        self.resource.sendPresentationTime(
            timestamp.highSeconds(),
            timestamp.lowSeconds(),
            timestamp.nanoseconds,
        );
        self.resource.sendReady();
        self.finished = true;
        if (self.session) |session| session.captured = true;
    }

    fn fail(self: *Frame, reason: ext.ImageCopyCaptureFrameV1.FailureReason) void {
        if (self.finished) return;
        self.finished = true;
        self.scheduled_output = null;
        self.cancelPendingCapture();
        self.resource.sendFailed(reason);
    }

    fn stopSession(self: *Frame) void {
        if (self.session) |session| session.stop();
    }
};

const CursorSession = struct {
    owner: *Self,
    resource: *ext.ImageCopyCaptureCursorSessionV1,
    target: ?CursorTarget,
    capture_session_created: bool = false,
    entered: bool = false,
    position: ?render.Position = null,
    hotspot: ?render.Position = null,

    fn create(owner: *Self, client: *wl.Client, id: u32, target: ?CursorTarget) !void {
        const resource = try ext.ImageCopyCaptureCursorSessionV1.create(client, 1, id);
        errdefer resource.destroy();
        const self = try owner.allocator.create(CursorSession);
        errdefer owner.allocator.destroy(self);
        self.* = .{ .owner = owner, .resource = resource, .target = target };
        try owner.cursor_sessions.append(owner.allocator, self);
        resource.setHandler(*CursorSession, handleRequest, handleDestroy, self);
        self.refresh();
    }

    fn handleRequest(
        resource: *ext.ImageCopyCaptureCursorSessionV1,
        request: ext.ImageCopyCaptureCursorSessionV1.Request,
        self: *CursorSession,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .get_capture_session => |get_session| {
                if (self.capture_session_created) {
                    resource.postError(.duplicate_session, "a cursor capture session already exists");
                    return;
                }
                self.capture_session_created = true;
                const target: ?Target = if (self.target) |value| .{ .cursor = value } else null;
                Session.create(self.owner, resource.getClient(), get_session.session, target, false) catch
                    resource.postNoMemory();
            },
        }
    }

    fn handleDestroy(_: *ext.ImageCopyCaptureCursorSessionV1, self: *CursorSession) void {
        for (self.owner.cursor_sessions.items, 0..) |session, index| {
            if (session != self) continue;
            _ = self.owner.cursor_sessions.swapRemove(index);
            break;
        }
        self.owner.allocator.destroy(self);
    }

    fn refresh(self: *CursorSession) void {
        const info = if (self.target) |target| self.owner.listener.cursor_info(
            self.owner.listener.context,
            target,
        ) else null;
        const entered = if (info) |value| value.entered else false;
        if (entered and !self.entered) self.resource.sendEnter();
        if (!entered and self.entered) self.resource.sendLeave();
        if (!entered) {
            self.entered = false;
            self.position = null;
            self.hotspot = null;
            return;
        }

        const value = info.?;
        if (self.position == null or !std.meta.eql(self.position.?, value.position)) {
            self.resource.sendPosition(value.position.x, value.position.y);
        }
        if (self.hotspot == null or !std.meta.eql(self.hotspot.?, value.hotspot)) {
            self.resource.sendHotspot(value.hotspot.x, value.hotspot.y);
        }
        self.entered = true;
        self.position = value.position;
        self.hotspot = value.hotspot;
    }

    fn invalidate(self: *CursorSession) void {
        if (self.entered) self.resource.sendLeave();
        self.target = null;
        self.entered = false;
        self.position = null;
        self.hotspot = null;
    }
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    security_context: *SecurityContext,
    sources: *ImageCaptureSource,
    linux_dmabuf: *LinuxDmabuf,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .event_loop = display.getEventLoop(),
        .security_context = security_context,
        .sources = sources,
        .linux_dmabuf = linux_dmabuf,
        .listener = listener,
        .sessions = .empty,
        .frames = .empty,
        .cursor_sessions = .empty,
    };
    errdefer self.sessions.deinit(allocator);
    errdefer self.frames.deinit(allocator);
    errdefer self.cursor_sessions.deinit(allocator);
    self.global = try wl.Global.create(
        display,
        ext.ImageCopyCaptureManagerV1,
        1,
        *Self,
        self,
        bind,
    );
    errdefer self.global.destroy();
    try security_context.restrictGlobal(self.global);
    errdefer security_context.unrestrictGlobal(self.global);
    sources.setInvalidationListener(.{
        .context = self,
        .invalidated = sourceInvalidated,
    });
}

pub fn deinit(self: *Self) void {
    self.sources.clearInvalidationListener();
    self.security_context.unrestrictGlobal(self.global);
    self.global.destroy();
    std.debug.assert(self.sessions.items.len == 0);
    std.debug.assert(self.frames.items.len == 0);
    std.debug.assert(self.cursor_sessions.items.len == 0);
    self.cursor_sessions.deinit(self.allocator);
    self.frames.deinit(self.allocator);
    self.sessions.deinit(self.allocator);
    self.* = undefined;
}

pub fn sessionCount(self: *const Self) usize {
    return self.sessions.items.len;
}

pub fn frameCount(self: *const Self) usize {
    return self.frames.items.len;
}

pub fn destinationBufferCount(self: *const Self) usize {
    var count: usize = 0;
    for (self.frames.items) |frame| {
        if (frame.destination.attached()) count += 1;
    }
    return count;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = ext.ImageCopyCaptureManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
}

fn handleManagerRequest(
    resource: *ext.ImageCopyCaptureManagerV1,
    request: ext.ImageCopyCaptureManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .create_session => |create| {
            const option_bits: u32 = @bitCast(create.options);
            if (option_bits & ~@as(u32, 1) != 0) {
                resource.postError(.invalid_option, "unknown capture option");
                return;
            }
            const target = self.sources.targetForResource(create.source);
            Session.create(
                self,
                resource.getClient(),
                create.session,
                if (target) |value| .{ .source = value } else null,
                create.options.paint_cursors,
            ) catch resource.postNoMemory();
        },
        .create_pointer_cursor_session => |create| {
            const source = self.sources.targetForResource(create.source);
            const binding = Seat.pointerBinding(create.pointer);
            const target: ?CursorTarget = if (source) |source_target|
                if (binding) |pointer| .{ .source = source_target, .seat = pointer.seat } else null
            else
                null;
            CursorSession.create(self, resource.getClient(), create.session, target) catch
                resource.postNoMemory();
        },
    }
}

pub fn refreshCursors(self: *Self) void {
    for (self.cursor_sessions.items) |session| session.refresh();
    for (self.sessions.items) |session| session.refreshCursorConstraints();
}

pub fn captureOutput(self: *Self, output: OutputLayout.Id) void {
    for (self.frames.items) |frame| {
        const scheduled = frame.scheduled_output orelse continue;
        if (!std.meta.eql(scheduled, output)) continue;
        frame.capture();
    }
}

pub fn needsComposedCursorFrame(self: *const Self, output: OutputLayout.Id) bool {
    for (self.frames.items) |frame| {
        if (frame.finished or frame.pending != null or !frame.paint_cursors) continue;
        const scheduled = frame.scheduled_output orelse continue;
        if (!std.meta.eql(scheduled, output)) continue;
        const target = frame.target orelse continue;
        if (target != .source) continue;
        const source = target.source;
        if (source != .output) continue;
        if (std.meta.eql(source.output, output)) return true;
    }
    return false;
}

pub fn removeOutput(self: *Self, output: OutputLayout.Id) void {
    for (self.frames.items) |frame| {
        const scheduled = frame.scheduled_output orelse continue;
        if (!std.meta.eql(scheduled, output)) continue;
        frame.scheduled_output = null;
        if (!frame.finished) frame.requestCapture();
    }
}

fn sourceInvalidated(context: *anyopaque, target: ImageCaptureSource.Target) void {
    const self: *Self = @ptrCast(@alignCast(context));
    for (self.frames.items) |frame| {
        const current = frame.target orelse continue;
        if (std.meta.eql(sourceForTarget(current), target)) frame.fail(.stopped);
    }
    for (self.sessions.items) |session| {
        const current = session.target orelse continue;
        if (std.meta.eql(sourceForTarget(current), target)) session.stop();
    }
    for (self.cursor_sessions.items) |session| {
        const current = session.target orelse continue;
        if (std.meta.eql(current.source, target)) session.invalidate();
    }
}

fn sourceForTarget(target: Target) ImageCaptureSource.Target {
    return switch (target) {
        .source => |source| source,
        .cursor => |cursor| cursor.source,
    };
}

fn shmPixelBuffer(buffer: *wl.shm.Buffer, expected: render.Size) ?render.PixelBuffer {
    const width = buffer.getWidth();
    const height = buffer.getHeight();
    const stride = buffer.getStride();
    if (width <= 0 or height <= 0 or stride <= 0 or @mod(stride, @sizeOf(u32)) != 0) {
        return null;
    }
    const size: render.Size = .{ .width = @intCast(width), .height = @intCast(height) };
    if (!std.meta.eql(size, expected)) return null;
    const stride_pixels: u32 = @intCast(@divExact(stride, @sizeOf(u32)));
    if (stride_pixels < size.width) return null;
    const format = buffer.getFormat();
    if (format != @intFromEnum(wl.Shm.Format.argb8888) and
        format != @intFromEnum(wl.Shm.Format.xrgb8888)) return null;
    const row_offset = std.math.mul(usize, size.height - 1, stride_pixels) catch return null;
    const required_pixels = std.math.add(usize, row_offset, size.width) catch return null;
    const data = buffer.getData() orelse return null;
    if (@intFromPtr(data) % @alignOf(u32) != 0) return null;
    const pixels: [*]u32 = @ptrCast(@alignCast(data));
    return .{
        .size = size,
        .stride_pixels = stride_pixels,
        .pixels = pixels[0..required_pixels],
    };
}

extern fn wl_shm_buffer_ref(buffer: *wl.shm.Buffer) *wl.shm.Buffer;
extern fn wl_shm_buffer_unref(buffer: *wl.shm.Buffer) void;

test "capture option mask accepts only paint cursors" {
    const valid: ext.ImageCopyCaptureManagerV1.Options = .{ .paint_cursors = true };
    try std.testing.expectEqual(@as(u32, 1), @as(u32, @bitCast(valid)));
}
