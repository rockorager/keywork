//! Wayring-side lifecycle for a pool of runtime-rendered DMA-BUFs.
//!
//! Vulkan ownership stays outside this type. Exported plane descriptors are
//! borrowed for a generation; their fds must outlive every corresponding
//! `wl_buffer`. A target is reusable only after `wl_buffer.release` and after
//! its DMA-BUF reservation object becomes writable.

const DmaBufPresenter = @This();

const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("wayring-protocols");
const linux = std.os.linux;

pub const Format = enum(u32) {
    argb8888 = 0x34325241,
    xrgb8888 = 0x34325258,
};

pub const Candidate = struct {
    format: Format,
    modifier: u64,
};

/// Vulkan has already filtered these fields for one-plane exportability and
/// color-attachment support. `fd` remains owned by the target set.
pub const ExportedPlane = struct {
    target_index: usize,
    fd: i32,
    width: u32,
    height: u32,
    offset: u32,
    stride: u32,
    format: Format,
    modifier: u64,
};

pub const Lease = struct {
    buffer: wayring.ObjectHandle,
    target_index: usize,
    generation: u64,
};

const State = enum { available, rendering, committed };

const Buffer = struct {
    handle: wayring.ObjectHandle,
    target_index: usize,
    poll_fd: i32,
    width: u32,
    height: u32,
    generation: u64,
    state: State = .available,
    retiring: bool = false,
};

allocator: std.mem.Allocator,
connection: *wayring.Connection,
surface: wayring.ObjectHandle,
factory: wayring.ObjectHandle,
generation: u64 = 0,
buffers: std.ArrayList(Buffer) = .empty,
compositor_candidates: std.ArrayList(Candidate) = .empty,

pub fn init(
    allocator: std.mem.Allocator,
    connection: *wayring.Connection,
    surface: wayring.ObjectHandle,
    factory: wayring.ObjectHandle,
) !DmaBufPresenter {
    _ = try connection.objectForHandle(surface, &protocol.wl_surface);
    const registered_factory = try connection.objectForHandle(factory, &protocol.zwp_linux_dmabuf_v1);
    if (registered_factory.version < 3) return error.DmaBufVersionTooOld;
    return .{
        .allocator = allocator,
        .connection = connection,
        .surface = surface,
        .factory = factory,
    };
}

pub fn deinit(self: *DmaBufPresenter) void {
    self.compositor_candidates.deinit(self.allocator);
    self.buffers.deinit(self.allocator);
    self.* = undefined;
}

pub fn currentGeneration(self: *const DmaBufPresenter) u64 {
    return self.generation;
}

pub fn bufferCount(self: *const DmaBufPresenter) usize {
    return self.buffers.items.len;
}

pub fn candidates(self: *const DmaBufPresenter) []const Candidate {
    return self.compositor_candidates.items;
}

/// Device candidates are ordered by renderer preference and must already have
/// passed Vulkan's plane-count, usage, and external-export checks.
pub fn chooseCandidate(compositor: []const Candidate, device: []const Candidate) ?Candidate {
    for (device) |device_candidate| {
        for (compositor) |compositor_candidate| {
            if (std.meta.eql(device_candidate, compositor_candidate)) return device_candidate;
        }
    }
    return null;
}

/// Consumes factory modifier announcements and `wl_buffer.release` events.
pub fn handleMessage(self: *DmaBufPresenter, message: *const wayring.Message) !void {
    if (message.object_id == self.factory.id) {
        switch (try protocol.zwp_linux_dmabuf_v1_types.decodeEvent(
            self.connection,
            self.factory,
            message,
        )) {
            .format => {}, // Version 3 modifier events are authoritative.
            .modifier => |event| {
                const format: Format = switch (event.format) {
                    @intFromEnum(Format.argb8888) => .argb8888,
                    @intFromEnum(Format.xrgb8888) => .xrgb8888,
                    else => return,
                };
                const candidate: Candidate = .{
                    .format = format,
                    .modifier = (@as(u64, event.modifier_hi) << 32) | event.modifier_lo,
                };
                for (self.compositor_candidates.items) |existing| {
                    if (std.meta.eql(existing, candidate)) return;
                }
                try self.compositor_candidates.append(self.allocator, candidate);
            },
        }
        return;
    }

    const index = self.findBufferById(message.object_id) orelse return error.UnknownPresenterObject;
    _ = try protocol.wl_buffer_types.decodeEvent(
        self.connection,
        self.buffers.items[index].handle,
        message,
    );
    if (self.buffers.items[index].state != .committed) return error.UnexpectedBufferRelease;
    if (self.buffers.items[index].retiring) {
        try self.destroyBuffer(index);
    } else {
        self.buffers.items[index].state = .available;
    }
}

/// Creates one `wl_buffer` per exported target and retires the prior
/// generation. A resize cannot race an active renderer lease.
pub fn createGeneration(self: *DmaBufPresenter, planes: []const ExportedPlane) !u64 {
    if (planes.len == 0) return error.EmptyTargetSet;
    for (self.buffers.items) |buffer| {
        if (buffer.state == .rendering) return error.BufferRendering;
    }
    if (self.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
    const next_generation = self.generation + 1;
    const start = self.buffers.items.len;
    errdefer self.rollbackNewBuffers(start);
    try self.buffers.ensureUnusedCapacity(self.allocator, planes.len);
    for (planes) |plane| {
        const handle = try self.createBuffer(plane);
        self.buffers.appendAssumeCapacity(.{
            .handle = handle,
            .target_index = plane.target_index,
            .poll_fd = plane.fd,
            .width = plane.width,
            .height = plane.height,
            .generation = next_generation,
        });
    }

    self.generation = next_generation;
    var index: usize = 0;
    while (index < self.buffers.items.len) {
        if (self.buffers.items[index].generation == next_generation) {
            index += 1;
            continue;
        }
        self.buffers.items[index].retiring = true;
        if (self.buffers.items[index].state == .available) {
            try self.destroyBuffer(index);
        } else {
            index += 1;
        }
    }
    return next_generation;
}

/// Returns a render target only after both protocol release and reservation
/// fences permit a new writer. A busy pool is normal and returns null.
pub fn acquire(self: *DmaBufPresenter) !?Lease {
    for (self.buffers.items) |*buffer| {
        if (buffer.generation != self.generation or buffer.retiring or buffer.state != .available) continue;
        if (!try pollWritable(buffer.poll_fd)) continue;
        buffer.state = .rendering;
        return .{
            .buffer = buffer.handle,
            .target_index = buffer.target_index,
            .generation = buffer.generation,
        };
    }
    return null;
}

pub fn cancel(self: *DmaBufPresenter, lease: Lease) !void {
    const buffer = try self.renderingBuffer(lease);
    buffer.state = .available;
}

/// Starts final retirement. Returns true when no compositor-held buffers
/// remain; committed buffers finish through their later release events.
pub fn retireAll(self: *DmaBufPresenter) !bool {
    for (self.buffers.items) |buffer| {
        if (buffer.state == .rendering) return error.BufferRendering;
    }
    var index: usize = 0;
    while (index < self.buffers.items.len) {
        self.buffers.items[index].retiring = true;
        if (self.buffers.items[index].state == .available) {
            try self.destroyBuffer(index);
        } else {
            index += 1;
        }
    }
    return self.buffers.items.len == 0;
}

/// Call only after the target's Vulkan submission fence has signaled and its
/// graphics-to-foreign ownership release has completed.
pub fn present(self: *DmaBufPresenter, lease: Lease) !void {
    const buffer = try self.renderingBuffer(lease);
    try protocol.wl_surface_types.requests.attach(self.connection, self.surface, buffer.handle, 0, 0);
    // Once attach is visible in the outbound queue, failures are connection-
    // fatal and this buffer must not be handed back to the renderer.
    buffer.state = .committed;
    try protocol.wl_surface_types.requests.damage_buffer(
        self.connection,
        self.surface,
        0,
        0,
        @intCast(buffer.width),
        @intCast(buffer.height),
    );
    try protocol.wl_surface_types.requests.commit(self.connection, self.surface);
}

fn createBuffer(self: *DmaBufPresenter, plane: ExportedPlane) !wayring.ObjectHandle {
    if (plane.fd < 0 or plane.width == 0 or plane.height == 0 or plane.stride == 0) return error.InvalidPlane;
    const width = std.math.cast(i32, plane.width) orelse return error.DimensionOverflow;
    const height = std.math.cast(i32, plane.height) orelse return error.DimensionOverflow;
    const params = try protocol.zwp_linux_dmabuf_v1_types.requests.create_params(self.connection, self.factory);
    errdefer protocol.zwp_linux_buffer_params_v1_types.requests.destroy(self.connection, params) catch {};

    const duplicate_result = linux.fcntl(plane.fd, linux.F.DUPFD_CLOEXEC, 0);
    if (linux.errno(duplicate_result) != .SUCCESS) return error.DuplicateFdFailed;
    const duplicate_fd: i32 = @intCast(duplicate_result);
    var duplicate_owned = true;
    defer if (duplicate_owned) {
        _ = linux.close(duplicate_fd);
    };
    try protocol.zwp_linux_buffer_params_v1_types.requests.add(
        self.connection,
        params,
        duplicate_fd,
        0,
        plane.offset,
        plane.stride,
        @truncate(plane.modifier >> 32),
        @truncate(plane.modifier),
    );
    duplicate_owned = false;
    const buffer = try protocol.zwp_linux_buffer_params_v1_types.requests.create_immed(
        self.connection,
        params,
        width,
        height,
        @intFromEnum(plane.format),
        0,
    );
    try protocol.zwp_linux_buffer_params_v1_types.requests.destroy(self.connection, params);
    return buffer;
}

fn rollbackNewBuffers(self: *DmaBufPresenter, start: usize) void {
    while (self.buffers.items.len > start) {
        const buffer = self.buffers.pop().?;
        protocol.wl_buffer_types.requests.destroy(self.connection, buffer.handle) catch {};
    }
}

fn destroyBuffer(self: *DmaBufPresenter, index: usize) !void {
    const buffer = self.buffers.items[index];
    try protocol.wl_buffer_types.requests.destroy(self.connection, buffer.handle);
    _ = self.buffers.orderedRemove(index);
}

fn findBufferById(self: *const DmaBufPresenter, id: u32) ?usize {
    for (self.buffers.items, 0..) |buffer, index| {
        if (buffer.handle.id == id) return index;
    }
    return null;
}

fn renderingBuffer(self: *DmaBufPresenter, lease: Lease) !*Buffer {
    const index = self.findBufferById(lease.buffer.id) orelse return error.StaleLease;
    const buffer = &self.buffers.items[index];
    if (buffer.handle.generation != lease.buffer.generation or
        buffer.generation != lease.generation or buffer.target_index != lease.target_index)
    {
        return error.StaleLease;
    }
    if (buffer.state != .rendering or buffer.retiring) return error.InvalidLease;
    return buffer;
}

fn pollWritable(fd: i32) !bool {
    var descriptor: linux.pollfd = .{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 };
    while (true) {
        const result = linux.poll(@ptrCast(&descriptor), 1, 0);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return false;
                if (descriptor.revents & (linux.POLL.NVAL | linux.POLL.ERR) != 0) return error.InvalidDmaBufFd;
                return descriptor.revents & linux.POLL.OUT != 0;
            },
            .INTR => continue,
            else => return error.PollFailed,
        }
    }
}

test "candidate intersection preserves renderer preference" {
    const compositor = [_]Candidate{
        .{ .format = .argb8888, .modifier = 7 },
        .{ .format = .xrgb8888, .modifier = 9 },
    };
    const device = [_]Candidate{
        .{ .format = .xrgb8888, .modifier = 9 },
        .{ .format = .argb8888, .modifier = 7 },
    };
    try std.testing.expectEqual(device[0], chooseCandidate(&compositor, &device).?);
    try std.testing.expect(chooseCandidate(&compositor, &.{.{ .format = .argb8888, .modifier = 1 }}) == null);
}

test "buffer generations wait for protocol release and writable reservation fences" {
    const Test = struct {
        fn register(connection: *wayring.Connection, id: u32, interface: *const wayring.Interface, version: u32) !wayring.ObjectHandle {
            return .{ .id = id, .generation = try connection.registerObject(id, interface, version) };
        }

        fn drain(connection: *wayring.Connection) !void {
            while (connection.nextBatch()) |batch| try connection.acknowledge(batch.token, batch.bytes.len);
        }

        fn transfer(sender: *wayring.Connection, receiver: *wayring.Connection) !void {
            const batch = sender.nextBatch() orelse return error.MissingBatch;
            try receiver.feed(batch.bytes, &.{});
            try sender.acknowledge(batch.token, batch.bytes.len);
        }

        fn release(server: *wayring.Connection, client: *wayring.Connection, presenter: *DmaBufPresenter, buffer: wayring.ObjectHandle) !void {
            try server.queue(buffer.id, 0, &.{});
            try transfer(server, client);
            var message = client.popMessage() orelse return error.MissingMessage;
            defer message.deinit();
            try presenter.handleMessage(&message);
        }
    };

    const fd = try std.posix.memfd_create("wayring-presenter-test", linux.MFD.CLOEXEC);
    defer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, 64 * 64 * 4)) != .SUCCESS) return error.TruncateFailed;

    var client = wayring.Connection.init(std.testing.allocator, .client, 4096);
    defer client.deinit();
    var server = wayring.Connection.init(std.testing.allocator, .server, 4096);
    defer server.deinit();
    const client_surface = try Test.register(&client, 1, &protocol.wl_surface, 6);
    _ = try Test.register(&server, 1, &protocol.wl_surface, 6);
    const client_factory = try Test.register(&client, 2, &protocol.zwp_linux_dmabuf_v1, 3);
    const server_factory = try Test.register(&server, 2, &protocol.zwp_linux_dmabuf_v1, 3);
    var presenter = try DmaBufPresenter.init(std.testing.allocator, &client, client_surface, client_factory);
    defer presenter.deinit();

    try server.queue(server_factory.id, 1, &.{
        .{ .uint = @intFromEnum(Format.xrgb8888) },
        .{ .uint = 0 },
        .{ .uint = 7 },
    });
    try Test.transfer(&server, &client);
    var modifier_message = client.popMessage() orelse return error.MissingMessage;
    defer modifier_message.deinit();
    try presenter.handleMessage(&modifier_message);
    try std.testing.expectEqualSlices(Candidate, &.{.{ .format = .xrgb8888, .modifier = 7 }}, presenter.candidates());

    const first_plane: ExportedPlane = .{
        .target_index = 10,
        .fd = fd,
        .width = 64,
        .height = 64,
        .offset = 0,
        .stride = 64 * 4,
        .format = .xrgb8888,
        .modifier = 7,
    };
    try std.testing.expectEqual(@as(u64, 1), try presenter.createGeneration(&.{first_plane}));
    const first_buffer = presenter.buffers.items[0].handle;
    _ = try Test.register(&server, first_buffer.id, &protocol.wl_buffer, 1);
    try Test.drain(&client);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));

    const first_lease = (try presenter.acquire()).?;
    try std.testing.expectEqual(@as(usize, 10), first_lease.target_index);
    try std.testing.expect((try presenter.acquire()) == null);
    try presenter.present(first_lease);
    try Test.drain(&client);
    try std.testing.expect((try presenter.acquire()) == null);
    try Test.release(&server, &client, &presenter, first_buffer);
    const reused = (try presenter.acquire()).?;
    try std.testing.expectEqual(first_buffer, reused.buffer);
    try presenter.cancel(reused);

    var second_plane = first_plane;
    second_plane.target_index = 20;
    try std.testing.expectEqual(@as(u64, 2), try presenter.createGeneration(&.{second_plane}));
    try std.testing.expectEqual(@as(usize, 1), presenter.bufferCount());
    const second_buffer = presenter.buffers.items[0].handle;
    _ = try Test.register(&server, second_buffer.id, &protocol.wl_buffer, 1);
    try Test.drain(&client);
    const second_lease = (try presenter.acquire()).?;
    try presenter.present(second_lease);
    try Test.drain(&client);

    var third_plane = first_plane;
    third_plane.target_index = 30;
    try std.testing.expectEqual(@as(u64, 3), try presenter.createGeneration(&.{third_plane}));
    try std.testing.expectEqual(@as(usize, 2), presenter.bufferCount());
    const third_buffer = presenter.buffers.items[1].handle;
    _ = try Test.register(&server, third_buffer.id, &protocol.wl_buffer, 1);
    try Test.release(&server, &client, &presenter, second_buffer);
    try std.testing.expectEqual(@as(usize, 1), presenter.bufferCount());
    try std.testing.expectEqual(third_buffer, presenter.buffers.items[0].handle);
    try std.testing.expect(try presenter.retireAll());
    try std.testing.expectEqual(@as(usize, 0), presenter.bufferCount());
}
