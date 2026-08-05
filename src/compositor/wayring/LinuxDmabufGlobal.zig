//! Native zwp_linux_dmabuf_v1 version 3 policy and retained buffer resources.

const LinuxDmabufGlobal = @This();

const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const render = @import("../render/types.zig");
const BufferResource = @import("BufferResource.zig");

const c = @cImport({
    @cInclude("linux/dma-buf.h");
    @cInclude("sys/ioctl.h");
});

const max_planes = render.max_dmabuf_planes;
const linear_modifier: u64 = 0;
const invalid_modifier: u64 = 0x00ff_ffff_ffff_ffff;

allocator: std.mem.Allocator,
server: *Server,
global_name: u32,
formats: []const render.DmabufFormatModifier,
validator: ?render.DmabufSourceValidator,

const Plane = struct { fd: std.posix.fd_t, offset: u32, stride: u32, modifier: u64 };
const Params = struct {
    owner: *LinuxDmabufGlobal,
    version: u32,
    planes: [max_planes]?Plane = @splat(null),
    used: bool = false,
};

pub fn init(
    self: *LinuxDmabufGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    formats: []const render.DmabufFormatModifier,
    validator: ?render.DmabufSourceValidator,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .global_name = undefined,
        .formats = formats,
        .validator = validator,
    };
    self.global_name = try server.createGlobal(
        &generated.zwp_linux_dmabuf_v1,
        3,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *LinuxDmabufGlobal) void {
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *LinuxDmabufGlobal = @ptrCast(@alignCast(context));
    const resource = client.createResource(
        id,
        &generated.zwp_linux_dmabuf_v1,
        version,
        .{ .context = self, .dispatch = dispatchFactory },
    ) catch return client.postNoMemory();
    if (version >= 3) {
        for (self.formats) |pair| generated.zwp_linux_dmabuf_v1_types.events.modifier(
            &client.connection,
            resource,
            pair.format,
            @truncate(pair.modifier >> 32),
            @truncate(pair.modifier),
        ) catch return client.postNoMemory();
    } else {
        for (self.formats, 0..) |pair, index| {
            if (pair.modifier != linear_modifier) continue;
            for (self.formats[0..index]) |previous| {
                if (previous.format == pair.format and previous.modifier == linear_modifier) break;
            } else generated.zwp_linux_dmabuf_v1_types.events.format(
                &client.connection,
                resource,
                pair.format,
            ) catch return client.postNoMemory();
        }
    }
}

fn dispatchFactory(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *LinuxDmabufGlobal = @ptrCast(@alignCast(context));
    switch (try generated.zwp_linux_dmabuf_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .create_params => |request| {
            const params = self.allocator.create(Params) catch return client.postNoMemory();
            errdefer self.allocator.destroy(params);
            const version = @min(
                3,
                try client.resourceVersion(resource, &generated.zwp_linux_dmabuf_v1),
            );
            params.* = .{ .owner = self, .version = version };
            _ = client.createResource(
                request.params_id,
                &generated.zwp_linux_buffer_params_v1,
                version,
                .{
                    .context = params,
                    .dispatch = dispatchParams,
                    .destroy = destroyParams,
                },
            ) catch return client.postNoMemory();
        },
        else => unreachable,
    }
}

fn dispatchParams(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const params: *Params = @ptrCast(@alignCast(context));
    switch (try generated.zwp_linux_buffer_params_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .add => |request| {
            const fd = try message.takeFd(request.fd);
            if (params.used) {
                _ = linux.close(fd);
                return paramsError(client, resource, .already_used, "parameters already used");
            }
            if (request.plane_idx >= max_planes) {
                _ = linux.close(fd);
                return paramsError(client, resource, .plane_idx, "plane index out of range");
            }
            if (params.planes[request.plane_idx] != null) {
                _ = linux.close(fd);
                return paramsError(client, resource, .plane_set, "plane already set");
            }
            params.planes[request.plane_idx] = .{
                .fd = fd,
                .offset = request.offset,
                .stride = request.stride,
                .modifier = @as(u64, request.modifier_hi) << 32 | request.modifier_lo,
            };
        },
        .create => |request| try createBuffer(
            params,
            client,
            resource,
            null,
            request.width,
            request.height,
            request.format,
            request.flags,
        ),
        .create_immed => |request| try createBuffer(
            params,
            client,
            resource,
            request.buffer_id,
            request.width,
            request.height,
            request.format,
            request.flags,
        ),
        else => unreachable,
    }
}

fn createBuffer(
    params: *Params,
    client: *Server.Client,
    params_resource: wayring.ObjectHandle,
    immediate_id: ?u32,
    width: i32,
    height: i32,
    format: u32,
    flags: u32,
) !void {
    if (params.used) return paramsError(client, params_resource, .already_used, "parameters already used");
    params.used = true;
    const descriptor = validate(
        params.planes,
        width,
        height,
        format,
        flags,
        params.version < 3,
        params.owner.formats,
    ) catch |err| {
        const code: generated.zwp_linux_buffer_params_v1_types.@"error" = switch (err) {
            error.Incomplete => .incomplete,
            error.InvalidFormat => .invalid_format,
            error.InvalidDimensions => .invalid_dimensions,
            error.OutOfBounds => .out_of_bounds,
            error.ImportFailed => .invalid_wl_buffer,
        };
        if (err == error.ImportFailed and immediate_id == null) return generated.zwp_linux_buffer_params_v1_types.events.failed(&client.connection, params_resource);
        return paramsError(client, params_resource, code, "invalid DMA-BUF descriptor");
    };
    const requires_direct_import = requiresDirectImport(descriptor.info, descriptor.modifier);
    if (requires_direct_import and params.owner.validator == null) {
        if (immediate_id == null) return generated.zwp_linux_buffer_params_v1_types.events.failed(&client.connection, params_resource);
        return paramsError(client, params_resource, .invalid_wl_buffer, "DMA-BUF import failed");
    }
    if (requires_direct_import) {
        if (params.owner.validator) |validator| validator.validate(validator.context, .{
            .size = descriptor.size,
            .format = format,
            .modifier = descriptor.modifier,
            .planes = descriptor.planes,
            .plane_count = descriptor.plane_count,
            .force_opaque = !descriptor.info.hasAlpha(),
        }) catch {
            if (immediate_id == null) return generated.zwp_linux_buffer_params_v1_types.events.failed(&client.connection, params_resource);
            return paramsError(client, params_resource, .invalid_wl_buffer, "DMA-BUF import failed");
        };
    }
    const holder = params.owner.allocator.create(BufferResource) catch return client.postNoMemory();
    const source_owner = params.owner.allocator.create(SourceOwner) catch {
        params.owner.allocator.destroy(holder);
        return client.postNoMemory();
    };
    source_owner.* = .{
        .allocator = params.owner.allocator,
        .planes = descriptor.planes,
        .plane_count = descriptor.plane_count,
        .references = 1,
    };
    for (params.planes[0..descriptor.plane_count]) |*plane| plane.* = null;
    holder.* = .{
        .allocator = params.owner.allocator,
        .content = .{ .dmabuf = .{
            .size = descriptor.size,
            .source = source_owner.source(
                format,
                descriptor.modifier,
                flags & 1 != 0,
                !descriptor.info.hasAlpha(),
            ),
            .source_cache_id = render.allocateSourceCacheId(),
        } },
    };
    const implementation: Server.ResourceImplementation = .{
        .context = holder,
        .dispatch = dispatchBuffer,
        .destroy = destroyBuffer,
    };
    const handle = if (immediate_id) |id|
        client.createResource(id, &generated.wl_buffer, 1, implementation) catch {
            holder.unreference();
            return client.postNoMemory();
        }
    else
        client.createServerResource(&generated.wl_buffer, 1, implementation) catch {
            holder.unreference();
            return client.postNoMemory();
        };
    if (immediate_id == null) generated.zwp_linux_buffer_params_v1_types.events.created(
        &client.connection,
        params_resource,
        handle,
    ) catch {
        client.destroyResource(handle) catch {};
        return client.postNoMemory();
    };
}

const Validated = struct {
    planes: [max_planes]render.DmabufPlane,
    plane_count: u8,
    size: render.Size,
    modifier: u64,
    info: render.DmabufFormat,
};
const ValidationError = error{ Incomplete, InvalidFormat, InvalidDimensions, OutOfBounds, ImportFailed };

fn requiresDirectImport(format: render.DmabufFormat, modifier: u64) bool {
    return modifier != linear_modifier or !format.isPackedRgb();
}

fn validate(
    planes: [max_planes]?Plane,
    width: i32,
    height: i32,
    format: u32,
    flags: u32,
    allow_implicit_modifier: bool,
    formats: []const render.DmabufFormatModifier,
) ValidationError!Validated {
    if (width <= 0 or height <= 0) return error.InvalidDimensions;
    const info = render.DmabufFormat.fromFourcc(format) orelse return error.InvalidFormat;
    if (!info.isPackedRgb() and (@rem(width, 2) != 0 or @rem(height, 2) != 0)) return error.InvalidDimensions;
    if (flags & ~@as(u32, 1) != 0) return error.ImportFailed;
    const count = info.planeCount();
    for (planes[0..count]) |plane| if (plane == null) return error.Incomplete;
    for (planes[count..]) |plane| if (plane != null) return error.Incomplete;
    const requested_modifier = planes[0].?.modifier;
    for (planes[1..count]) |plane| if (plane.?.modifier != requested_modifier)
        return error.InvalidFormat;
    const implicit_modifier = allow_implicit_modifier and requested_modifier == invalid_modifier;
    const modifier = if (implicit_modifier) linear_modifier else requested_modifier;
    if (!render.DmabufFormatModifier.contains(formats, format, modifier)) return error.InvalidFormat;
    const size: render.Size = .{ .width = @intCast(width), .height = @intCast(height) };
    var result: [max_planes]render.DmabufPlane = @splat(.{});
    for (planes[0..count], 0..) |optional, index| {
        const plane = optional.?;
        const fd_size = std.c.lseek(plane.fd, 0, std.c.SEEK.END);
        if (fd_size <= 0) return error.ImportFailed;
        const required: usize = if (modifier == linear_modifier) required: {
            const plane_index: u8 = @intCast(index);
            const row_bytes = info.planeRowBytes(plane_index, size.width) orelse
                return error.OutOfBounds;
            const plane_height = info.planeHeight(plane_index, size.height) orelse
                return error.OutOfBounds;
            const alignment = info.planeAlignment();
            if (plane.stride < row_bytes or plane.stride % alignment != 0 or
                plane.offset % alignment != 0) return error.OutOfBounds;
            const row_offset = std.math.mul(u64, plane_height - 1, plane.stride) catch
                return error.OutOfBounds;
            const required_offset = std.math.add(u64, plane.offset, row_offset) catch
                return error.OutOfBounds;
            const required_end = std.math.add(u64, required_offset, row_bytes) catch
                return error.OutOfBounds;
            if (required_end == 0 or required_end > @as(u64, @intCast(fd_size)) or
                required_end > std.math.maxInt(usize)) return error.OutOfBounds;
            break :required @intCast(required_end);
        } else non_linear: {
            if (@as(u64, @intCast(fd_size)) > std.math.maxInt(usize))
                return error.OutOfBounds;
            break :non_linear @intCast(fd_size);
        };
        result[index] = .{ .fd = plane.fd, .offset = plane.offset, .stride = plane.stride, .required_bytes = @intCast(required) };
    }
    return .{ .planes = result, .plane_count = count, .size = size, .modifier = modifier, .info = info };
}

const SourceOwner = struct {
    allocator: std.mem.Allocator,
    planes: [max_planes]render.DmabufPlane,
    plane_count: u8,
    references: usize,
    fn source(
        self: *SourceOwner,
        format: u32,
        modifier: u64,
        y_inverted: bool,
        force_opaque: bool,
    ) render.DmabufSource {
        return .{
            .context = self,
            .format = format,
            .modifier = modifier,
            .planes = self.planes,
            .plane_count = self.plane_count,
            .y_inverted = y_inverted,
            .force_opaque = force_opaque,
            .retain = retain,
            .release = release,
            .begin_cpu_read = begin,
            .end_cpu_read = end,
            .export_read_fence = fence,
        };
    }
    fn retain(context: *anyopaque) void {
        const self: *SourceOwner = @ptrCast(@alignCast(context));
        self.references += 1;
    }
    fn release(context: *anyopaque) void {
        const self: *SourceOwner = @ptrCast(@alignCast(context));
        self.references -= 1;
        if (self.references == 0) {
            for (self.planes[0..self.plane_count]) |plane| _ = linux.close(plane.fd);
            self.allocator.destroy(self);
        }
    }
    fn begin(context: *anyopaque) bool {
        const self: *SourceOwner = @ptrCast(@alignCast(context));
        for (self.planes[0..self.plane_count], 0..) |plane, index| {
            if (syncDmaBuf(plane.fd, c.DMA_BUF_SYNC_READ)) continue;
            for (self.planes[0..index]) |started| {
                _ = syncDmaBuf(started.fd, c.DMA_BUF_SYNC_READ | c.DMA_BUF_SYNC_END);
            }
            return false;
        }
        return true;
    }
    fn end(context: *anyopaque) bool {
        const self: *SourceOwner = @ptrCast(@alignCast(context));
        var succeeded = true;
        for (self.planes[0..self.plane_count]) |plane| {
            succeeded = syncDmaBuf(
                plane.fd,
                c.DMA_BUF_SYNC_READ | c.DMA_BUF_SYNC_END,
            ) and succeeded;
        }
        return succeeded;
    }
    fn fence(context: *anyopaque, plane_index: u8) ?std.posix.fd_t {
        const self: *SourceOwner = @ptrCast(@alignCast(context));
        if (plane_index >= self.plane_count) return null;
        var export_sync_file: c.dma_buf_export_sync_file = .{
            .flags = c.DMA_BUF_SYNC_READ,
            .fd = -1,
        };
        while (true) {
            const result = c.ioctl(
                self.planes[plane_index].fd,
                c.DMA_BUF_IOCTL_EXPORT_SYNC_FILE,
                &export_sync_file,
            );
            if (result >= 0) return export_sync_file.fd;
            switch (std.posix.errno(result)) {
                .INTR, .AGAIN => continue,
                else => return null,
            }
        }
    }
};

fn syncDmaBuf(fd: std.posix.fd_t, flags: u64) bool {
    while (true) {
        var sync: c.dma_buf_sync = .{ .flags = flags };
        const result = c.ioctl(fd, c.DMA_BUF_IOCTL_SYNC, &sync);
        if (result >= 0) return true;
        switch (std.posix.errno(result)) {
            .INTR, .AGAIN => continue,
            else => return false,
        }
    }
}

fn paramsError(
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    code: generated.zwp_linux_buffer_params_v1_types.@"error",
    text: []const u8,
) !void {
    return client.postError(resource, @intFromEnum(code), text);
}

fn destroyParams(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const params: *Params = @ptrCast(@alignCast(context));
    for (params.planes) |plane| {
        if (plane) |value| _ = linux.close(value.fd);
    }
    params.owner.allocator.destroy(params);
}

fn dispatchBuffer(
    _: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    _ = try generated.wl_buffer_types.decodeRequest(&client.connection, resource, message);
}

fn destroyBuffer(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const holder: *BufferResource = @ptrCast(@alignCast(context));
    holder.resourceDestroyed();
}

test "DMA-BUF descriptors reject malformed planes and implicit v3 modifiers" {
    const format = @intFromEnum(render.DmabufFormat.argb8888);
    const formats = [_]render.DmabufFormatModifier{
        .{ .format = format, .modifier = linear_modifier },
    };
    var planes: [max_planes]?Plane = @splat(null);
    try std.testing.expectError(
        error.Incomplete,
        validate(planes, 2, 2, format, 0, false, &formats),
    );

    const fd = try std.posix.memfd_create("keywork-native-dmabuf-validation", linux.MFD.CLOEXEC);
    defer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, 16)) != .SUCCESS) return error.TruncateFailed;
    planes[0] = .{ .fd = fd, .offset = 0, .stride = 8, .modifier = linear_modifier };
    const descriptor = try validate(planes, 2, 2, format, 0, false, &formats);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 2 }, descriptor.size);
    try std.testing.expectEqual(@as(usize, 16), descriptor.planes[0].required_bytes);

    planes[0].?.stride = 4;
    try std.testing.expectError(
        error.OutOfBounds,
        validate(planes, 2, 2, format, 0, false, &formats),
    );
    planes[0].?.stride = 8;
    planes[0].?.modifier = invalid_modifier;
    try std.testing.expectError(
        error.InvalidFormat,
        validate(planes, 2, 2, format, 0, false, &formats),
    );
    _ = try validate(planes, 2, 2, format, 0, true, &formats);
}

test "linear packed DMA-BUF sources use the renderer fallback path" {
    try std.testing.expect(!requiresDirectImport(.argb8888, linear_modifier));
    try std.testing.expect(requiresDirectImport(.argb8888, 1));
    try std.testing.expect(requiresDirectImport(.nv12, linear_modifier));
}

test "native DMA-BUF async create allocates and retires a server wl_buffer" {
    const core = @import("wayring-core");
    const format = @intFromEnum(render.DmabufFormat.argb8888);
    const formats = [_]render.DmabufFormatModifier{
        .{ .format = format, .modifier = linear_modifier },
    };
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var global: LinuxDmabufGlobal = undefined;
    try global.init(std.testing.allocator, &server, &formats, null);
    defer global.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch {};

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
    var global_message = peer.popMessage() orelse return error.MissingGlobal;
    defer global_message.deinit();
    const advertised = (try core.decodeRegistryEvent(&global_message, registry.id)).global;
    try std.testing.expectEqualStrings(generated.zwp_linux_dmabuf_v1.name, advertised.interface);
    const factory: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            advertised.name,
            advertised.interface,
            3,
            3,
            &generated.zwp_linux_dmabuf_v1,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        _ = try generated.zwp_linux_dmabuf_v1_types.decodeEvent(
            &peer,
            factory,
            &message,
        );
    }

    const fd = try std.posix.memfd_create("keywork-native-dmabuf-protocol", linux.MFD.CLOEXEC);
    var fd_owned = true;
    defer if (fd_owned) {
        _ = linux.close(fd);
    };
    if (linux.errno(linux.ftruncate(fd, 16)) != .SUCCESS) return error.TruncateFailed;
    const params = try generated.zwp_linux_dmabuf_v1_types.requests.create_params(
        &peer,
        factory,
    );
    try generated.zwp_linux_buffer_params_v1_types.requests.add(
        &peer,
        params,
        fd,
        0,
        0,
        8,
        0,
        0,
    );
    fd_owned = false;
    try generated.zwp_linux_buffer_params_v1_types.requests.create(
        &peer,
        params,
        2,
        2,
        format,
        0,
    );
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var created_message = peer.popMessage() orelse return error.MissingCreated;
    defer created_message.deinit();
    const created = (try generated.zwp_linux_buffer_params_v1_types.decodeEvent(
        &peer,
        params,
        &created_message,
    )).created;
    const generation = try peer.registerObject(created.buffer, &generated.wl_buffer, 1);
    try peer.resumeParsing();
    const buffer: wayring.ObjectHandle = .{
        .id = created.buffer,
        .generation = generation,
    };
    try generated.wl_buffer_types.requests.destroy(&peer, buffer);
    try generated.zwp_linux_buffer_params_v1_types.requests.destroy(&peer, params);
    try transferToServer(&peer, client);
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
