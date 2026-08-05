//! XDG toplevel icon metadata and buffer lifetime handling.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const XdgShell = @import("../XdgShell.zig");
const MatureXdgShell = @import("xdg_shell.zig");

const wl = wayland.server.wl;
const xdg = wayland.server.xdg;

allocator: std.mem.Allocator,
global: *wl.Global,
xdg_shell: *MatureXdgShell,
core: *XdgShell,
icons: std.ArrayList(*Icon),

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    xdg_shell: *MatureXdgShell,
    core: *XdgShell,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .xdg_shell = xdg_shell,
        .core = core,
        .icons = .empty,
    };
    errdefer self.icons.deinit(allocator);
    self.global = try wl.Global.create(
        display,
        xdg.ToplevelIconManagerV1,
        1,
        *Self,
        self,
        bind,
    );
}

pub fn deinit(self: *Self) void {
    std.debug.assert(self.icons.items.len == 0);
    self.global.destroy();
    self.icons.deinit(self.allocator);
    self.* = undefined;
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = xdg.ToplevelIconManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleManagerRequest, null, self);
    resource.sendDone();
}

fn handleManagerRequest(
    resource: *xdg.ToplevelIconManagerV1,
    request: xdg.ToplevelIconManagerV1.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .create_icon => |create| Icon.create(self, resource, create.id) catch
            resource.postNoMemory(),
        .set_icon => |set| self.setIcon(resource, set.toplevel, set.icon),
    }
}

fn setIcon(
    self: *Self,
    manager_resource: *xdg.ToplevelIconManagerV1,
    toplevel_resource: *xdg.Toplevel,
    icon_resource: ?*xdg.ToplevelIconV1,
) void {
    const client = manager_resource.getClient();
    if (toplevel_resource.getClient() != client) {
        client.postImplementationError("xdg_toplevel belongs to another client");
        return;
    }
    const toplevel = self.xdg_shell.toplevelFromResource(toplevel_resource) orelse {
        client.postImplementationError("invalid xdg_toplevel resource");
        return;
    };

    var snapshot: ?XdgShell.ToplevelIcon = null;
    if (icon_resource) |resource| {
        if (resource.getClient() != client) {
            client.postImplementationError("xdg_toplevel_icon_v1 belongs to another client");
            return;
        }
        const data = resource.getUserData() orelse {
            client.postImplementationError("invalid xdg_toplevel_icon_v1 resource");
            return;
        };
        const icon: *Icon = @ptrCast(@alignCast(data));
        if (icon.manager != self or icon.resource != resource) {
            client.postImplementationError("invalid xdg_toplevel_icon_v1 resource");
            return;
        }
        snapshot = icon.snapshotForAssignment() catch |err| switch (err) {
            error.OutOfMemory => {
                manager_resource.postNoMemory();
                return;
            },
            error.InvalidBuffer => {
                resource.postError(.invalid_buffer, "icon buffer is no longer readable");
                return;
            },
        };
    }
    self.core.setPendingToplevelIcon(toplevel.window_id, snapshot);
}

const Icon = struct {
    manager: *Self,
    resource: *xdg.ToplevelIconV1,
    name: ?[:0]u8 = null,
    buffers: std.ArrayList(*Buffer) = .empty,
    immutable: bool = false,

    fn create(
        manager: *Self,
        manager_resource: *xdg.ToplevelIconManagerV1,
        id: u32,
    ) !void {
        const resource = try xdg.ToplevelIconV1.create(
            manager_resource.getClient(),
            manager_resource.getVersion(),
            id,
        );
        errdefer resource.destroy();
        const self = try manager.allocator.create(Icon);
        errdefer manager.allocator.destroy(self);
        self.* = .{ .manager = manager, .resource = resource };
        try manager.icons.append(manager.allocator, self);
        resource.setHandler(*Icon, handleRequest, handleDestroy, self);
    }

    fn handleRequest(
        resource: *xdg.ToplevelIconV1,
        request: xdg.ToplevelIconV1.Request,
        self: *Icon,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            .set_name => |set| self.setName(resource, set.icon_name),
            .add_buffer => |add| self.addBuffer(resource, add.buffer, add.scale),
        }
    }

    fn setName(
        self: *Icon,
        resource: *xdg.ToplevelIconV1,
        name_z: [*:0]const u8,
    ) void {
        if (self.rejectMutation(resource)) return;
        const name = std.mem.span(name_z);
        if (!std.unicode.utf8ValidateSlice(name)) {
            resource.getClient().postImplementationError("icon name is not valid UTF-8");
            return;
        }
        const copy = self.manager.allocator.dupeSentinel(u8, name, 0) catch {
            resource.postNoMemory();
            return;
        };
        if (self.name) |previous| self.manager.allocator.free(previous);
        self.name = copy;
    }

    fn addBuffer(
        self: *Icon,
        icon_resource: *xdg.ToplevelIconV1,
        buffer_resource: *wl.Buffer,
        scale: i32,
    ) void {
        if (self.rejectMutation(icon_resource)) return;
        const shm = wl.shm.Buffer.get(@ptrCast(buffer_resource)) orelse {
            icon_resource.postError(.invalid_buffer, "icon buffer is not backed by wl_shm");
            return;
        };
        const width = shm.getWidth();
        if (width <= 0 or shm.getHeight() != width or shm.getStride() <= 0) {
            icon_resource.postError(.invalid_buffer, "icon buffer must be a valid square");
            return;
        }
        const buffer = Buffer.create(self, buffer_resource, shm, scale) catch {
            icon_resource.postNoMemory();
            return;
        };
        for (self.buffers.items, 0..) |existing, index| {
            if (!sameVariant(existing.shm.getWidth(), existing.scale, width, scale)) continue;
            existing.destroy();
            self.buffers.items[index] = buffer;
            return;
        }
        self.buffers.append(self.manager.allocator, buffer) catch {
            buffer.destroy();
            icon_resource.postNoMemory();
        };
    }

    fn rejectMutation(self: *const Icon, resource: *xdg.ToplevelIconV1) bool {
        if (!self.immutable) return false;
        resource.postError(.immutable, "icon was already assigned to a toplevel");
        return true;
    }

    const SnapshotError = error{ OutOfMemory, InvalidBuffer };

    fn snapshotForAssignment(self: *Icon) SnapshotError!?XdgShell.ToplevelIcon {
        const result = try self.snapshot();
        self.immutable = true;
        return result;
    }

    fn snapshot(self: *Icon) SnapshotError!?XdgShell.ToplevelIcon {
        if (self.name == null and self.buffers.items.len == 0) return null;
        const allocator = self.manager.allocator;
        const name = if (self.name) |value|
            try allocator.dupeSentinel(u8, value, 0)
        else
            null;
        errdefer if (name) |value| allocator.free(value);
        const buffers = try allocator.alloc(XdgShell.ToplevelIconBuffer, self.buffers.items.len);
        var initialized: usize = 0;
        errdefer {
            for (buffers[0..initialized]) |buffer| allocator.free(buffer.data);
            allocator.free(buffers);
        }
        for (self.buffers.items, buffers) |source, *destination| {
            destination.* = try source.snapshot(allocator);
            initialized += 1;
        }
        return .{ .name = name, .buffers = buffers };
    }

    fn handleDestroy(_: *xdg.ToplevelIconV1, self: *Icon) void {
        if (self.name) |name| self.manager.allocator.free(name);
        for (self.buffers.items) |buffer| buffer.destroy();
        self.buffers.deinit(self.manager.allocator);
        for (self.manager.icons.items, 0..) |icon, index| {
            if (icon != self) continue;
            _ = self.manager.icons.orderedRemove(index);
            self.manager.allocator.destroy(self);
            return;
        }
        unreachable;
    }
};

const Buffer = struct {
    icon: *Icon,
    resource: ?*wl.Buffer,
    shm: *wl.shm.Buffer,
    scale: i32,
    destroy_listener: wl.Listener(*wl.Resource),

    fn create(
        icon: *Icon,
        resource: *wl.Buffer,
        shm: *wl.shm.Buffer,
        scale: i32,
    ) !*Buffer {
        const self = try icon.manager.allocator.create(Buffer);
        self.* = .{
            .icon = icon,
            .resource = resource,
            .shm = wl_shm_buffer_ref(shm),
            .scale = scale,
            .destroy_listener = wl.Listener(*wl.Resource).init(handleResourceDestroy),
        };
        @as(*wl.Resource, @ptrCast(resource)).addDestroyListener(&self.destroy_listener);
        return self;
    }

    fn destroy(self: *Buffer) void {
        if (self.resource != null) self.destroy_listener.link.remove();
        wl_shm_buffer_unref(self.shm);
        self.icon.manager.allocator.destroy(self);
    }

    fn snapshot(
        self: *Buffer,
        allocator: std.mem.Allocator,
    ) Icon.SnapshotError!XdgShell.ToplevelIconBuffer {
        const width = self.shm.getWidth();
        const height = self.shm.getHeight();
        const stride = self.shm.getStride();
        if (width <= 0 or height != width or stride <= 0) return error.InvalidBuffer;
        const byte_count = std.math.mul(
            usize,
            @intCast(stride),
            @intCast(height),
        ) catch return error.InvalidBuffer;
        const data = try allocator.alloc(u8, byte_count);
        errdefer allocator.free(data);
        self.shm.beginAccess();
        defer self.shm.endAccess();
        const source = self.shm.getData() orelse return error.InvalidBuffer;
        @memcpy(data, @as([*]const u8, @ptrCast(source))[0..byte_count]);
        return .{
            .size = @intCast(width),
            .scale = self.scale,
            .format = self.shm.getFormat(),
            .stride = @intCast(stride),
            .data = data,
        };
    }

    fn handleResourceDestroy(
        listener: *wl.Listener(*wl.Resource),
        _: *wl.Resource,
    ) void {
        const self: *Buffer = @fieldParentPtr("destroy_listener", listener);
        listener.link.remove();
        self.resource = null;
        self.icon.resource.postError(.no_buffer, "icon buffer was destroyed before the icon");
    }
};

fn sameVariant(buffer_size: i32, buffer_scale: i32, size: i32, scale: i32) bool {
    return buffer_size == size and buffer_scale == scale;
}

extern fn wl_shm_buffer_ref(buffer: *wl.shm.Buffer) *wl.shm.Buffer;
extern fn wl_shm_buffer_unref(buffer: *wl.shm.Buffer) void;

test "icon buffer variants are keyed by size and scale" {
    try std.testing.expect(sameVariant(64, 2, 64, 2));
    try std.testing.expect(!sameVariant(64, 2, 32, 2));
    try std.testing.expect(!sameVariant(64, 2, 64, 1));
}

test "icon becomes immutable only after its assignment snapshot succeeds" {
    const name = try std.testing.allocator.dupeSentinel(u8, "terminal", 0);
    defer std.testing.allocator.free(name);
    var manager: Self = undefined;
    var icon: Icon = .{
        .manager = &manager,
        .resource = undefined,
        .name = name,
    };

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    manager.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, icon.snapshotForAssignment());
    try std.testing.expect(!icon.immutable);

    manager.allocator = std.testing.allocator;
    var snapshot = (try icon.snapshotForAssignment()).?;
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(icon.immutable);
}
