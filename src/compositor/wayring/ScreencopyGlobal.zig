//! Privileged native `wlr-screencopy` SHM compatibility policy.
//!
//! Protocol frames retain client buffers independently from their resources.
//! One compositor-owned staging target serializes renderer readback and
//! positional SHM writes without mapping client-controlled memory.

const ScreencopyGlobal = @This();

const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const keywork_loop = @import("keywork-loop");
const Server = @import("wayring-server");
const AsyncShmWrite = @import("AsyncShmWrite.zig");
const BufferResource = @import("BufferResource.zig");
const OutputGlobal = @import("OutputGlobal.zig");
const SecurityContextGlobal = @import("SecurityContextGlobal.zig");
const ShmGlobal = @import("ShmGlobal.zig");
const presentation = @import("../presentation.zig");
const render = @import("../render/types.zig");
const shm = @import("shm.zig");

const IoUringLoop = keywork_loop.IoUringLoop;
const advertised_version: u32 = 3;

allocator: std.mem.Allocator,
server: *Server,
loop: *IoUringLoop,
output: *OutputGlobal,
listener: Listener,
global_name: u32,
managers: std.ArrayList(*Manager) = .empty,
frames: std.ArrayList(*Frame) = .empty,
generation: u64 = 0,
active: ?*Frame = null,
staging: []u32 = &.{},
staging_size: ?render.Size = null,
shutting_down: bool = false,

pub const Listener = struct {
    context: *anyopaque,
    constraints: *const fn (*anyopaque) ?render.Size,
    schedule: *const fn (*anyopaque, wait_for_damage: bool) bool,
    capture: *const fn (
        *anyopaque,
        []const render.Command,
        render.Scale,
        render.PixelBuffer,
    ) anyerror!?std.posix.fd_t,
    complete: *const fn (*anyopaque, render.PixelBuffer) bool,
};

const Manager = struct {
    owner: *ScreencopyGlobal,
    version: u32,
    references: usize = 1,
    baseline: ?u64 = null,

    fn reference(self: *Manager) !void {
        if (self.references == std.math.maxInt(usize)) return error.ReferenceOverflow;
        self.references += 1;
    }

    fn unreference(self: *Manager) void {
        std.debug.assert(self.references > 0);
        self.references -= 1;
        if (self.references != 0) return;
        const owner = self.owner;
        for (owner.managers.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = owner.managers.orderedRemove(index);
            owner.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

const FrameState = enum { advertised, armed, capturing, writing, terminal };

const Frame = struct {
    owner: *ScreencopyGlobal,
    manager: *Manager,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    size: ?render.Size,
    overlay_cursor: bool,
    state: FrameState = .advertised,
    resource_alive: bool = true,
    with_damage: bool = false,
    aborted: bool = false,
    capture_generation: u64 = 0,
    timestamp: presentation.Timestamp = .{ .seconds = 0, .nanoseconds = 0 },
    destination: ?*BufferResource = null,
    sync_fd: std.posix.fd_t = -1,
    sync_handle: ?IoUringLoop.Handle = null,
    write: ?*AsyncShmWrite = null,
};

pub fn init(
    self: *ScreencopyGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    loop: *IoUringLoop,
    output: *OutputGlobal,
    security_context: *SecurityContextGlobal,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .loop = loop,
        .output = output,
        .listener = listener,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.zwlr_screencopy_manager_v1,
        advertised_version,
        .{
            .context = self,
            .bind = bind,
            .filter_context = security_context,
            .filter = SecurityContextGlobal.allowUnconfined,
        },
    );
}

pub fn deinit(self: *ScreencopyGlobal) void {
    self.server.removeGlobal(self.global_name) catch unreachable;
    std.debug.assert(self.active == null);
    std.debug.assert(self.frames.items.len == 0 and self.managers.items.len == 0);
    self.allocator.free(self.staging);
    self.frames.deinit(self.allocator);
    self.managers.deinit(self.allocator);
    self.* = undefined;
}

pub fn shutdown(self: *ScreencopyGlobal) void {
    self.shutting_down = true;
    for (self.frames.items) |frame| {
        if (frame.state == .capturing or frame.state == .writing) {
            frame.aborted = true;
            if (frame.write) |write| write.cancel() catch {};
        }
    }
}

pub fn outputRemoved(self: *ScreencopyGlobal) void {
    var index: usize = 0;
    while (index < self.frames.items.len) {
        const frame = self.frames.items[index];
        if (frame.state == .capturing or frame.state == .writing) {
            frame.aborted = true;
            if (frame.write) |write| write.cancel() catch {};
            index += 1;
        } else if (frame.state != .terminal) {
            finish(frame, false);
            if (index < self.frames.items.len and self.frames.items[index] == frame)
                index += 1;
        } else {
            index += 1;
        }
    }
}

/// Invalidates old-size work that has not started. Active readback/write work
/// keeps its old composition and staging storage until completion.
pub fn outputResized(self: *ScreencopyGlobal) void {
    for (self.managers.items) |manager| manager.baseline = null;
    var index: usize = 0;
    while (index < self.frames.items.len) {
        const frame = self.frames.items[index];
        if (frame.state == .advertised or frame.state == .armed) {
            finish(frame, false);
            if (index < self.frames.items.len and self.frames.items[index] == frame)
                index += 1;
        } else {
            index += 1;
        }
    }
}

pub fn hasPendingIo(self: *const ScreencopyGlobal) bool {
    return self.active != null;
}

/// Captures at most one armed frame from this completed output composition.
/// Command storage remains borrowed only for the synchronous capture callback.
pub fn composedFrame(
    self: *ScreencopyGlobal,
    desktop_commands: []const render.Command,
    all_commands: []const render.Command,
    scale: render.Scale,
    output_size: render.Size,
    timestamp: presentation.Timestamp,
) void {
    if (self.shutting_down) return;
    self.generation +%= 1;
    if (self.generation == 0) {
        self.generation = 1;
        for (self.managers.items) |manager| manager.baseline = null;
    }
    if (self.active != null) return;
    const frame = self.nextEligibleFrame() orelse return;
    if (frame.size == null or !std.meta.eql(frame.size.?, output_size)) {
        finish(frame, false);
        self.scheduleEligible();
        return;
    }
    self.ensureStaging(output_size) catch {
        frame.client.postNoMemory() catch {};
        finish(frame, false);
        self.scheduleEligible();
        return;
    };
    frame.state = .capturing;
    frame.capture_generation = self.generation;
    frame.timestamp = timestamp;
    self.active = frame;
    const pixels = self.pixelBuffer();
    const commands = if (frame.overlay_cursor) all_commands else desktop_commands;
    const sync_fd = self.listener.capture(
        self.listener.context,
        commands,
        scale,
        pixels,
    ) catch {
        finish(frame, false);
        self.scheduleEligible();
        return;
    };
    if (sync_fd) |fd| {
        frame.sync_fd = fd;
        frame.sync_handle = self.loop.queue(
            frame,
            readbackReady,
            frame,
            prepareReadback,
        ) catch {
            frame.sync_fd = -1;
            _ = linux.close(fd);
            if (!self.listener.complete(self.listener.context, pixels)) {
                finish(frame, false);
                self.scheduleEligible();
                return;
            }
            self.startWrite(frame);
            return;
        };
        return;
    }
    self.startWrite(frame);
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *ScreencopyGlobal = @ptrCast(@alignCast(context));
    const manager = self.allocator.create(Manager) catch return client.postNoMemory();
    errdefer self.allocator.destroy(manager);
    self.managers.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    manager.* = .{ .owner = self, .version = version };
    _ = client.createResource(id, &generated.zwlr_screencopy_manager_v1, version, .{
        .context = manager,
        .dispatch = dispatchManager,
        .destroy = destroyManager,
    }) catch return client.postNoMemory();
    self.managers.appendAssumeCapacity(manager);
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const manager: *Manager = @ptrCast(@alignCast(context));
    switch (try generated.zwlr_screencopy_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .capture_output => |request| {
            const valid_output = manager.owner.output.bindingHandle(client, request.output) != null;
            try createFrame(
                manager,
                client,
                request.frame,
                request.overlay_cursor != 0,
                if (valid_output) manager.owner.listener.constraints(
                    manager.owner.listener.context,
                ) else null,
            );
        },
        .capture_output_region => |request| try createFrame(
            manager,
            client,
            request.frame,
            request.overlay_cursor != 0,
            null,
        ),
    }
}

fn destroyManager(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const manager: *Manager = @ptrCast(@alignCast(context));
    manager.unreference();
}

fn createFrame(
    manager: *Manager,
    client: *Server.Client,
    id: u32,
    overlay_cursor: bool,
    size: ?render.Size,
) !void {
    const owner = manager.owner;
    const frame = owner.allocator.create(Frame) catch return client.postNoMemory();
    errdefer owner.allocator.destroy(frame);
    owner.frames.ensureUnusedCapacity(owner.allocator, 1) catch
        return client.postNoMemory();
    manager.reference() catch return client.postNoMemory();
    errdefer manager.unreference();
    frame.* = .{
        .owner = owner,
        .manager = manager,
        .client = client,
        .resource = undefined,
        .size = size,
        .overlay_cursor = overlay_cursor,
    };
    frame.resource = client.createResource(
        id,
        &generated.zwlr_screencopy_frame_v1,
        @min(manager.version, generated.zwlr_screencopy_frame_v1.version),
        .{
            .context = frame,
            .dispatch = dispatchFrame,
            .destroy = destroyFrame,
        },
    ) catch return client.postNoMemory();
    owner.frames.appendAssumeCapacity(frame);
    const capture_size = size orelse {
        finish(frame, false);
        return;
    };
    const stride = std.math.mul(u32, capture_size.width, @sizeOf(u32)) catch {
        finish(frame, false);
        return;
    };
    generated.zwlr_screencopy_frame_v1_types.events.buffer(
        &client.connection,
        frame.resource,
        @intFromEnum(shm.Format.argb8888),
        capture_size.width,
        capture_size.height,
        stride,
    ) catch {
        client.postNoMemory() catch {};
        return;
    };
    if (manager.version >= 3) generated.zwlr_screencopy_frame_v1_types.events.buffer_done(
        &client.connection,
        frame.resource,
    ) catch client.postNoMemory() catch {};
}

fn dispatchFrame(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const frame: *Frame = @ptrCast(@alignCast(context));
    switch (try generated.zwlr_screencopy_frame_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .copy => |request| try arm(frame, client, request.buffer, false),
        .copy_with_damage => |request| try arm(frame, client, request.buffer, true),
    }
}

fn destroyFrame(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const frame: *Frame = @ptrCast(@alignCast(context));
    std.debug.assert(frame.resource_alive);
    frame.resource_alive = false;
    if (frame.state == .capturing or frame.state == .writing) {
        frame.aborted = true;
        if (frame.write) |write| write.cancel() catch {};
        return;
    }
    freeFrame(frame);
}

fn arm(
    frame: *Frame,
    client: *Server.Client,
    buffer: u32,
    with_damage: bool,
) !void {
    if (frame.state == .terminal) return;
    if (frame.state != .advertised) return client.postError(
        frame.resource,
        @intFromEnum(generated.zwlr_screencopy_frame_v1_types.@"error".already_used),
        "screencopy frame was already used",
    );
    const size = frame.size orelse return;
    const object = client.connection.object(buffer) orelse return error.UnknownBuffer;
    const destination = ShmGlobal.cloneBufferResource(client, .{
        .id = buffer,
        .generation = object.generation,
    }) catch return client.postNoMemory();
    errdefer destination.unreference();
    const valid = switch (destination.content) {
        .shm => |shm_buffer| shm_buffer.format == .argb8888 and
            shm_buffer.width == size.width and shm_buffer.height == size.height and
            shm_buffer.stride == @as(usize, size.width) * @sizeOf(u32),
        .dmabuf, .single_pixel => false,
    };
    if (!valid) return client.postError(
        frame.resource,
        @intFromEnum(generated.zwlr_screencopy_frame_v1_types.@"error".invalid_buffer),
        "buffer does not match screencopy constraints",
    );
    frame.destination = destination;
    frame.with_damage = with_damage;
    frame.state = .armed;
    if (frame.owner.active == null and frame.owner.frameEligible(frame)) {
        if (!frame.owner.listener.schedule(frame.owner.listener.context, false))
            finish(frame, false);
    }
}

fn prepareReadback(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
    const frame: *Frame = @ptrCast(@alignCast(context));
    sqe.prep_poll_add(frame.sync_fd, linux.POLL.IN | linux.POLL.ERR | linux.POLL.HUP);
}

fn readbackReady(
    context: *anyopaque,
    _: *IoUringLoop,
    completion: IoUringLoop.Completion,
) !void {
    const frame: *Frame = @ptrCast(@alignCast(context));
    frame.sync_handle = null;
    if (completion.result < 0) frame.aborted = true;
    const fd = frame.sync_fd;
    frame.sync_fd = -1;
    if (fd >= 0) _ = linux.close(fd);
    if (!frame.owner.listener.complete(frame.owner.listener.context, frame.owner.pixelBuffer()) or
        frame.aborted or !frame.resource_alive)
    {
        finish(frame, false);
        frame.owner.scheduleEligible();
        return;
    }
    frame.owner.startWrite(frame);
}

fn startWrite(self: *ScreencopyGlobal, frame: *Frame) void {
    if (frame.aborted or !frame.resource_alive) {
        finish(frame, false);
        self.scheduleEligible();
        return;
    }
    const destination = frame.destination orelse {
        finish(frame, false);
        self.scheduleEligible();
        return;
    };
    const buffer = switch (destination.content) {
        .shm => |value| value,
        .dmabuf, .single_pixel => unreachable,
    };
    const write = AsyncShmWrite.create(
        self.allocator,
        self.loop,
        buffer,
        std.mem.sliceAsBytes(self.staging),
        frame,
        writeComplete,
    ) catch {
        finish(frame, false);
        self.scheduleEligible();
        return;
    };
    frame.write = write;
    frame.state = .writing;
    write.start() catch {
        if (frame.write == write and !write.isTerminal()) {
            write.deinit();
            frame.write = null;
            finish(frame, false);
            self.scheduleEligible();
        }
    };
}

fn writeComplete(context: ?*anyopaque, write: *AsyncShmWrite) void {
    const frame: *Frame = @ptrCast(@alignCast(context.?));
    const succeeded = if (write.result()) |_| true else |_| false;
    std.debug.assert(frame.write == write);
    frame.write = null;
    write.deinit();
    finish(frame, succeeded and !frame.aborted);
    frame.owner.scheduleEligible();
}

fn finish(frame: *Frame, succeeded: bool) void {
    if (frame.state == .terminal) return;
    const owner = frame.owner;
    std.debug.assert(frame.sync_handle == null and frame.write == null);
    frame.state = .terminal;
    if (owner.active == frame) owner.active = null;
    if (succeeded and frame.resource_alive and frame.client.state == .active) {
        frame.manager.baseline = frame.capture_generation;
        generated.zwlr_screencopy_frame_v1_types.events.flags(
            &frame.client.connection,
            frame.resource,
            0,
        ) catch {
            frame.client.postNoMemory() catch {};
        };
        if (frame.with_damage and frame.manager.version >= 2) {
            const size = frame.size.?;
            generated.zwlr_screencopy_frame_v1_types.events.damage(
                &frame.client.connection,
                frame.resource,
                0,
                0,
                size.width,
                size.height,
            ) catch frame.client.postNoMemory() catch {};
        }
        generated.zwlr_screencopy_frame_v1_types.events.ready(
            &frame.client.connection,
            frame.resource,
            frame.timestamp.highSeconds(),
            frame.timestamp.lowSeconds(),
            frame.timestamp.nanoseconds,
        ) catch frame.client.postNoMemory() catch {};
    } else if (frame.resource_alive and frame.client.state == .active) {
        generated.zwlr_screencopy_frame_v1_types.events.failed(
            &frame.client.connection,
            frame.resource,
        ) catch frame.client.postNoMemory() catch {};
    }
    if (frame.destination) |destination| destination.unreference();
    frame.destination = null;
    if (!frame.resource_alive) freeFrame(frame);
}

fn freeFrame(frame: *Frame) void {
    const owner = frame.owner;
    std.debug.assert(owner.active != frame);
    std.debug.assert(frame.sync_handle == null and frame.write == null);
    if (frame.destination) |destination| destination.unreference();
    for (owner.frames.items, 0..) |candidate, index| {
        if (candidate != frame) continue;
        _ = owner.frames.orderedRemove(index);
        const manager = frame.manager;
        owner.allocator.destroy(frame);
        manager.unreference();
        return;
    }
    unreachable;
}

fn frameEligible(self: *const ScreencopyGlobal, frame: *const Frame) bool {
    if (frame.state != .armed) return false;
    return !frame.with_damage or frame.manager.baseline == null or
        frame.manager.baseline.? != self.generation;
}

fn nextEligibleFrame(self: *ScreencopyGlobal) ?*Frame {
    for (self.frames.items) |frame| if (self.frameEligible(frame)) return frame;
    return null;
}

fn scheduleEligible(self: *ScreencopyGlobal) void {
    if (self.shutting_down or self.active != null) return;
    while (self.nextEligibleFrame()) |frame| {
        if (self.listener.schedule(self.listener.context, false)) return;
        finish(frame, false);
    }
}

fn ensureStaging(self: *ScreencopyGlobal, size: render.Size) !void {
    if (self.staging_size) |current| if (std.meta.eql(current, size)) return;
    const replacement = try self.allocator.alloc(u32, try size.pixelCount());
    self.allocator.free(self.staging);
    self.staging = replacement;
    self.staging_size = size;
}

fn pixelBuffer(self: *ScreencopyGlobal) render.PixelBuffer {
    const size = self.staging_size.?;
    return .{
        .size = size,
        .stride_pixels = size.width,
        .pixels = self.staging,
    };
}
