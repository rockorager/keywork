//! Native immutable xdg-toplevel-icon-v1 metadata and SHM lifetime policy.

const XdgToplevelIconGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const BufferResource = @import("BufferResource.zig");
const XdgShell = @import("XdgShell.zig");
const shm = @import("shm.zig");

const advertised_version: u32 = 1;

allocator: std.mem.Allocator,
server: *Server,
shell: *XdgShell,
reader: shm.Reader,
global_name: u32,
icons: std.ArrayList(*Icon) = .empty,

const Icon = struct {
    owner: *XdgToplevelIconGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    name: ?[]u8 = null,
    buffers: std.ArrayList(*Buffer) = .empty,
    immutable: bool = false,

    fn rejectMutation(self: *const Icon) !void {
        if (!self.immutable) return;
        return self.client.postError(
            self.resource,
            @intFromEnum(generated.xdg_toplevel_icon_v1_types.@"error".immutable),
            "icon was already assigned to a toplevel",
        );
    }

    const SnapshotError = error{ OutOfMemory, InvalidBuffer };

    fn snapshot(self: *const Icon) SnapshotError!?XdgShell.ToplevelIcon {
        if (self.name == null and self.buffers.items.len == 0) return null;
        const allocator = self.owner.allocator;
        const name = if (self.name) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (name) |value| allocator.free(value);
        const buffers = try allocator.alloc(
            XdgShell.ToplevelIconBuffer,
            self.buffers.items.len,
        );
        var initialized: usize = 0;
        errdefer {
            for (buffers[0..initialized]) |*buffer| buffer.snapshot.deinit();
            allocator.free(buffers);
        }
        for (self.buffers.items, buffers) |source, *destination| {
            destination.* = .{
                .snapshot = source.source.copy(
                    allocator,
                    self.owner.reader,
                    null,
                    null,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidBuffer,
                },
                .scale = source.scale,
            };
            initialized += 1;
        }
        return .{ .name = name, .buffers = buffers };
    }

    fn deinit(self: *Icon) void {
        if (self.name) |name| self.owner.allocator.free(name);
        for (self.buffers.items) |buffer| buffer.destroy();
        self.buffers.deinit(self.owner.allocator);
        const owner = self.owner;
        for (owner.icons.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = owner.icons.orderedRemove(index);
            owner.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

const Buffer = struct {
    icon: *Icon,
    resource: ?*BufferResource,
    source: shm.Buffer,
    scale: i32,

    fn create(
        icon: *Icon,
        resource: *BufferResource,
        source: shm.Buffer,
        scale: i32,
    ) error{OutOfMemory}!*Buffer {
        const self = icon.owner.allocator.create(Buffer) catch
            return error.OutOfMemory;
        errdefer icon.owner.allocator.destroy(self);
        var retained = source.clone() catch return error.OutOfMemory;
        errdefer retained.deinit();
        self.* = .{
            .icon = icon,
            .resource = resource,
            .source = retained,
            .scale = scale,
        };
        resource.addDestroyListener(.{
            .context = self,
            .destroyed = resourceDestroyed,
        }) catch return error.OutOfMemory;
        return self;
    }

    fn destroy(self: *Buffer) void {
        if (self.resource) |resource| resource.removeDestroyListener(self);
        self.source.deinit();
        self.icon.owner.allocator.destroy(self);
    }

    fn resourceDestroyed(context: *anyopaque) void {
        const self: *Buffer = @ptrCast(@alignCast(context));
        self.resource = null;
        if (self.icon.client.state != .active) return;
        self.icon.client.postError(
            self.icon.resource,
            @intFromEnum(generated.xdg_toplevel_icon_v1_types.@"error".no_buffer),
            "icon buffer was destroyed before the icon",
        ) catch {};
    }
};

pub fn init(
    self: *XdgToplevelIconGlobal,
    allocator: std.mem.Allocator,
    server: *Server,
    shell: *XdgShell,
    reader: shm.Reader,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .shell = shell,
        .reader = reader,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(
        &generated.xdg_toplevel_icon_manager_v1,
        advertised_version,
        .{ .context = self, .bind = bind },
    );
}

pub fn deinit(self: *XdgToplevelIconGlobal) void {
    std.debug.assert(self.icons.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.icons.deinit(self.allocator);
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *XdgToplevelIconGlobal = @ptrCast(@alignCast(context));
    const resource = client.createResource(
        id,
        &generated.xdg_toplevel_icon_manager_v1,
        version,
        .{ .context = self, .dispatch = dispatchManager },
    ) catch return client.postNoMemory();
    generated.xdg_toplevel_icon_manager_v1_types.events.done(
        &client.connection,
        resource,
    ) catch return client.postNoMemory();
}

fn dispatchManager(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const self: *XdgToplevelIconGlobal = @ptrCast(@alignCast(context));
    switch (try generated.xdg_toplevel_icon_manager_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .create_icon => |request| try self.createIcon(client, resource, request.id),
        .set_icon => |request| try self.setIcon(
            client,
            request.toplevel,
            request.icon,
        ),
    }
}

fn createIcon(
    self: *XdgToplevelIconGlobal,
    client: *Server.Client,
    manager_resource: wayring.ObjectHandle,
    id: u32,
) !void {
    const icon = self.allocator.create(Icon) catch return client.postNoMemory();
    errdefer self.allocator.destroy(icon);
    self.icons.ensureUnusedCapacity(self.allocator, 1) catch
        return client.postNoMemory();
    icon.* = .{
        .owner = self,
        .client = client,
        .resource = undefined,
    };
    const version = try client.resourceVersion(
        manager_resource,
        &generated.xdg_toplevel_icon_manager_v1,
    );
    icon.resource = client.createResource(
        id,
        &generated.xdg_toplevel_icon_v1,
        version,
        .{
            .context = icon,
            .dispatch = dispatchIcon,
            .destroy = destroyIcon,
        },
    ) catch return client.postNoMemory();
    self.icons.appendAssumeCapacity(icon);
}

fn setIcon(
    self: *XdgToplevelIconGlobal,
    client: *Server.Client,
    toplevel_id: u32,
    icon_id: ?u32,
) !void {
    const toplevel_object = client.connection.object(toplevel_id) orelse
        return error.UnknownToplevel;
    const toplevel: wayring.ObjectHandle = .{
        .id = toplevel_id,
        .generation = toplevel_object.generation,
    };
    var snapshot: ?XdgShell.ToplevelIcon = null;
    var assigned_icon: ?*Icon = null;
    if (icon_id) |id| {
        const object = client.connection.object(id) orelse return error.UnknownIcon;
        const icon: *Icon = @ptrCast(@alignCast(try client.resourceContext(
            .{ .id = id, .generation = object.generation },
            &generated.xdg_toplevel_icon_v1,
        )));
        if (icon.owner != self or icon.client != client) return error.WrongIcon;
        snapshot = icon.snapshot() catch |err| switch (err) {
            error.OutOfMemory => return client.postNoMemory(),
            error.InvalidBuffer => return client.postError(
                icon.resource,
                @intFromEnum(
                    generated.xdg_toplevel_icon_v1_types.@"error".invalid_buffer,
                ),
                "icon buffer is no longer readable",
            ),
        };
        assigned_icon = icon;
    }
    var snapshot_owned = snapshot != null;
    defer if (snapshot_owned) snapshot.?.deinit(self.allocator);
    try self.shell.setPendingToplevelIcon(client, toplevel, snapshot);
    snapshot_owned = false;
    if (assigned_icon) |icon| icon.immutable = true;
}

fn dispatchIcon(
    context: *anyopaque,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    message: *wayring.Message,
) !void {
    const icon: *Icon = @ptrCast(@alignCast(context));
    switch (try generated.xdg_toplevel_icon_v1_types.decodeRequest(
        &client.connection,
        resource,
        message,
    )) {
        .destroy => {},
        .set_name => |request| {
            try icon.rejectMutation();
            if (!std.unicode.utf8ValidateSlice(request.icon_name))
                return error.InvalidUtf8;
            const copy = icon.owner.allocator.dupe(u8, request.icon_name) catch
                return client.postNoMemory();
            if (icon.name) |previous| icon.owner.allocator.free(previous);
            icon.name = copy;
        },
        .add_buffer => |request| {
            try icon.rejectMutation();
            const object = client.connection.object(request.buffer) orelse
                return error.UnknownBuffer;
            const resource_context: *BufferResource = @ptrCast(@alignCast(
                try client.resourceContext(
                    .{ .id = request.buffer, .generation = object.generation },
                    &generated.wl_buffer,
                ),
            ));
            const source = switch (resource_context.content) {
                .shm => |buffer| buffer,
                .dmabuf, .single_pixel => return client.postError(
                    resource,
                    @intFromEnum(
                        generated.xdg_toplevel_icon_v1_types.@"error".invalid_buffer,
                    ),
                    "icon buffer is not backed by wl_shm",
                ),
            };
            if (source.width == 0 or source.height != source.width or source.stride == 0)
                return client.postError(
                    resource,
                    @intFromEnum(
                        generated.xdg_toplevel_icon_v1_types.@"error".invalid_buffer,
                    ),
                    "icon buffer must be a valid square",
                );
            const buffer = Buffer.create(
                icon,
                resource_context,
                source,
                request.scale,
            ) catch return client.postNoMemory();
            for (icon.buffers.items, 0..) |existing, index| {
                if (!sameVariant(
                    existing.source.width,
                    existing.scale,
                    source.width,
                    request.scale,
                )) continue;
                existing.destroy();
                icon.buffers.items[index] = buffer;
                return;
            }
            icon.buffers.append(icon.owner.allocator, buffer) catch {
                buffer.destroy();
                return client.postNoMemory();
            };
        },
    }
}

fn destroyIcon(
    context: *anyopaque,
    _: *Server.Client,
    _: wayring.ObjectHandle,
) void {
    const icon: *Icon = @ptrCast(@alignCast(context));
    icon.deinit();
}

fn sameVariant(buffer_size: u32, buffer_scale: i32, size: u32, scale: i32) bool {
    return buffer_size == size and buffer_scale == scale;
}

test "toplevel icons retain assigned SHM state and enforce buffer lifetime" {
    const core = @import("wayring-core");
    const linux = std.os.linux;
    const CompositorGlobal = @import("CompositorGlobal.zig");
    const ShmGlobal = @import("ShmGlobal.zig");
    const SurfaceTree = @import("SurfaceTree.zig");

    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var shm_global: ShmGlobal = undefined;
    try shm_global.init(std.testing.allocator, &server);
    defer shm_global.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var tree = SurfaceTree.init(std.testing.allocator);
    defer tree.deinit();
    var shell: XdgShell = undefined;
    try shell.init(std.testing.allocator, &server, &tree, .{
        .context = &tree,
        .surface_size = testSurfaceSize,
        .output_bounds = testOutputBounds,
    });
    defer shell.deinit();
    var icons: XdgToplevelIconGlobal = undefined;
    try icons.init(
        std.testing.allocator,
        &server,
        &shell,
        .{ .context = &icons, .read = readIconBuffer },
    );
    defer icons.deinit();
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
    var shm_name: u32 = 0;
    var shell_name: u32 = 0;
    var icon_manager_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.wl_shm.name))
            shm_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.xdg_wm_base.name))
            shell_name = global.name;
        if (std.mem.eql(
            u8,
            global.interface,
            generated.xdg_toplevel_icon_manager_v1.name,
        )) {
            try std.testing.expectEqual(advertised_version, global.version);
            icon_manager_name = global.name;
        }
    }
    try std.testing.expect(compositor_name != 0);
    try std.testing.expect(shm_name != 0);
    try std.testing.expect(shell_name != 0);
    try std.testing.expect(icon_manager_name != 0);

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
    const shm_resource: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            shm_name,
            generated.wl_shm.name,
            2,
            4,
            &generated.wl_shm,
        ),
    };
    const wm_base: wayring.ObjectHandle = .{
        .id = 5,
        .generation = try core.bind(
            &peer,
            registry.id,
            shell_name,
            generated.xdg_wm_base.name,
            6,
            5,
            &generated.xdg_wm_base,
        ),
    };
    const manager: wayring.ObjectHandle = .{
        .id = 6,
        .generation = try core.bind(
            &peer,
            registry.id,
            icon_manager_name,
            generated.xdg_toplevel_icon_manager_v1.name,
            advertised_version,
            6,
            &generated.xdg_toplevel_icon_manager_v1,
        ),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var manager_done = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == shm_resource.id) {
            _ = try generated.wl_shm_types.decodeEvent(&peer, shm_resource, &message);
        } else if (message.object_id == manager.id) {
            switch (try generated.xdg_toplevel_icon_manager_v1_types.decodeEvent(
                &peer,
                manager,
                &message,
            )) {
                .done => manager_done = true,
                .icon_size => return error.UnexpectedIconSize,
            }
        } else return error.UnexpectedBindEvent;
    }
    try std.testing.expect(manager_done);

    const surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const xdg_surface = try generated.xdg_wm_base_types.requests.get_xdg_surface(
        &peer,
        wm_base,
        surface,
    );
    const toplevel = try generated.xdg_surface_types.requests.get_toplevel(
        &peer,
        xdg_surface,
    );
    const fd = try std.posix.memfd_create("keywork-native-toplevel-icons", linux.MFD.CLOEXEC);
    var fd_owned = true;
    defer if (fd_owned) {
        _ = linux.close(fd);
    };
    if (linux.errno(linux.ftruncate(fd, 32)) != .SUCCESS)
        return error.TruncateFailed;
    const source_pixels = [_]u32{
        0x1020_3040,
        0x5060_7080,
        0x90a0_b0c0,
        0xd0e0_f000,
        0x1122_3344,
        0x5566_7788,
        0x99aa_bbcc,
        0xddee_ff00,
    };
    const source_bytes = std.mem.sliceAsBytes(&source_pixels);
    const write_result = linux.pwrite(fd, source_bytes.ptr, source_bytes.len, 0);
    if (linux.errno(write_result) != .SUCCESS or write_result != source_bytes.len)
        return error.WriteFailed;
    const pool = try generated.wl_shm_types.requests.create_pool(
        &peer,
        shm_resource,
        fd,
        32,
    );
    fd_owned = false;
    const first_buffer = try generated.wl_shm_pool_types.requests.create_buffer(
        &peer,
        pool,
        0,
        2,
        2,
        8,
        @intFromEnum(shm.Format.argb8888),
    );
    const second_buffer = try generated.wl_shm_pool_types.requests.create_buffer(
        &peer,
        pool,
        16,
        2,
        2,
        8,
        @intFromEnum(shm.Format.xrgb8888),
    );
    const icon = try generated.xdg_toplevel_icon_manager_v1_types.requests.create_icon(
        &peer,
        manager,
    );
    try generated.xdg_toplevel_icon_manager_v1_types.requests.destroy(&peer, manager);
    const replacement_manager: wayring.ObjectHandle = .{
        .id = 30,
        .generation = try core.bind(
            &peer,
            registry.id,
            icon_manager_name,
            generated.xdg_toplevel_icon_manager_v1.name,
            advertised_version,
            30,
            &generated.xdg_toplevel_icon_manager_v1,
        ),
    };
    try generated.xdg_toplevel_icon_v1_types.requests.set_name(
        &peer,
        icon,
        "document",
    );
    try generated.xdg_toplevel_icon_v1_types.requests.add_buffer(
        &peer,
        icon,
        first_buffer,
        2,
    );
    // The latest size/scale variant replaces the earlier retained source.
    try generated.xdg_toplevel_icon_v1_types.requests.add_buffer(
        &peer,
        icon,
        first_buffer,
        2,
    );
    try generated.xdg_toplevel_icon_manager_v1_types.requests.set_icon(
        &peer,
        replacement_manager,
        toplevel,
        icon,
    );
    try generated.xdg_toplevel_icon_v1_types.requests.destroy(&peer, icon);
    try generated.wl_buffer_types.requests.destroy(&peer, first_buffer);
    try generated.wl_shm_pool_types.requests.destroy(&peer, pool);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try generated.xdg_toplevel_icon_manager_v1_types.requests.set_icon(
        &peer,
        replacement_manager,
        toplevel,
        null,
    );
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToServer(&peer, client);
    try std.testing.expectEqual(Server.ClientState.active, client.state);
    try std.testing.expectEqual(@as(usize, 0), icons.icons.items.len);

    const toplevel_handle: wayring.ObjectHandle = .{
        .id = toplevel.id,
        .generation = client.connection.object(toplevel.id).?.generation,
    };
    try std.testing.expect(try shell.toplevelIcon(client, toplevel_handle) == null);
    var transaction = compositor.popTransaction() orelse return error.MissingCommit;
    defer transaction.deinit();
    try std.testing.expectEqual(
        .configure_only,
        (try shell.handleCommit(&transaction.entries[0])).disposition,
    );
    const info = (try shell.toplevelIcon(client, toplevel_handle)) orelse
        return error.MissingToplevelIcon;
    try std.testing.expectEqualStrings("document", info.name.?);
    try std.testing.expectEqual(@as(usize, 1), info.buffers.len);
    try std.testing.expectEqual(
        @import("../render/types.zig").Size{ .width = 2, .height = 2 },
        info.buffers[0].snapshot.size,
    );
    try std.testing.expectEqual(@as(usize, 4), info.buffers[0].snapshot.pixels.len);
    try std.testing.expectEqualSlices(
        u32,
        source_pixels[0..4],
        info.buffers[0].snapshot.pixels,
    );
    try std.testing.expectEqual(@as(i32, 2), info.buffers[0].scale);
    try std.testing.expect(!info.buffers[0].snapshot.force_opaque);
    var clear_transaction = compositor.popTransaction() orelse return error.MissingCommit;
    defer clear_transaction.deinit();
    _ = try shell.handleCommit(&clear_transaction.entries[0]);
    try std.testing.expect(try shell.toplevelIcon(client, toplevel_handle) == null);

    try transferFromServer(&peer, client);
    var replacement_done = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == replacement_manager.id) {
            switch (try generated.xdg_toplevel_icon_manager_v1_types.decodeEvent(
                &peer,
                replacement_manager,
                &message,
            )) {
                .done => replacement_done = true,
                .icon_size => return error.UnexpectedIconSize,
            }
        }
    }
    try std.testing.expect(replacement_done);

    const live_icon = try generated.xdg_toplevel_icon_manager_v1_types.requests.create_icon(
        &peer,
        replacement_manager,
    );
    try generated.xdg_toplevel_icon_v1_types.requests.add_buffer(
        &peer,
        live_icon,
        second_buffer,
        1,
    );
    try transferToServer(&peer, client);
    try generated.wl_buffer_types.requests.destroy(&peer, second_buffer);
    try std.testing.expectError(
        error.ProtocolError,
        transferToServer(&peer, client),
    );
    try std.testing.expectEqual(Server.ClientState.protocol_error, client.state);
    try transferFromServer(&peer, client);
    var got_no_buffer = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != 1) continue;
        switch (try core.decodeDisplayEvent(&message)) {
            .error_event => |event| if (event.object_id == live_icon.id and
                event.code == @intFromEnum(
                    generated.xdg_toplevel_icon_v1_types.@"error".no_buffer,
                ))
            {
                got_no_buffer = true;
            },
            .delete_id => {},
        }
    }
    try std.testing.expect(got_no_buffer);
}

fn testSurfaceSize(
    _: *anyopaque,
    _: *const @import("CompositorGlobal.zig").Surface,
) ?@import("../render/types.zig").Size {
    return .{ .width = 1280, .height = 720 };
}

fn testOutputBounds(_: *anyopaque) @import("../render/types.zig").Rect {
    return .{ .x = 0, .y = 0, .width = 1280, .height = 720 };
}

fn readIconBuffer(_: *anyopaque, fd: i32, offset: u64, destination: []u8) !void {
    var completed: usize = 0;
    while (completed < destination.len) {
        const result = std.os.linux.pread(
            fd,
            destination[completed..].ptr,
            destination.len - completed,
            @intCast(offset + completed),
        );
        switch (std.os.linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.UnexpectedEndOfFile;
                completed += result;
            },
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
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
