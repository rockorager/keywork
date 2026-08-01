//! io_uring-backed Wayring client bootstrap and required global discovery.

const Client = @This();

const std = @import("std");
const keywork_loop = @import("keywork-loop");
const wayring = @import("wayring");
const IoUringTransport = @import("wayring-uring");
const protocol = @import("wayring-protocols");

const IoUringLoop = keywork_loop.IoUringLoop;

pub const Notification = enum { ready, outputs_changed, eof, fatal };
pub const Notify = *const fn (context: *anyopaque, client: *Client, notification: Notification) anyerror!void;
pub const MessageNotify = *const fn (context: *anyopaque, client: *Client, message: *wayring.Message) anyerror!void;

pub const Surface = struct {
    surface: wayring.ObjectHandle,
    viewport: ?wayring.ObjectHandle,
    fractional_scale: ?wayring.ObjectHandle,
};

pub const Window = struct {
    surface: wayring.ObjectHandle,
    xdg_surface: wayring.ObjectHandle,
    toplevel: wayring.ObjectHandle,
    viewport: ?wayring.ObjectHandle,
    fractional_scale: ?wayring.ObjectHandle,
};

pub const DmaBufCandidate = struct {
    format: u32,
    modifier: u64,
};

pub const OutputInfo = struct {
    name: []const u8,
    width: f32,
    height: f32,
    scale: f32,
};

pub const Seat = struct {
    handle: wayring.ObjectHandle,
    capabilities: u32,
};

const SyncPhase = enum { globals, bindings };

const Global = struct {
    name: u32,
    handle: wayring.ObjectHandle,
};

const Output = struct {
    global_name: u32,
    handle: wayring.ObjectHandle,
    name: ?[]u8 = null,
    mode_width: i32 = 0,
    mode_height: i32 = 0,
    scale: u32 = 1,
    dirty: bool = false,
};

allocator: std.mem.Allocator,
loop: *IoUringLoop,
connection: wayring.Connection,
transport: IoUringTransport,
notify_context: *anyopaque,
notify: Notify,
message_notify: MessageNotify,
display: wayring.ObjectHandle,
registry: wayring.ObjectHandle,
sync_callback: ?wayring.ObjectHandle,
compositor: ?Global = null,
wm_base: ?Global = null,
dmabuf: ?Global = null,
shm: ?Global = null,
seat: ?Global = null,
data_device_manager: ?Global = null,
cursor_shape_manager: ?Global = null,
activation: ?Global = null,
viewporter: ?Global = null,
fractional_scale_manager: ?Global = null,
layer_shell: ?Global = null,
session_lock_manager: ?Global = null,
outputs: std.ArrayList(Output) = .empty,
seat_capabilities: u32 = 0,
seat_claimed: bool = false,
dmabuf_candidates: std.ArrayList(DmaBufCandidate) = .empty,
sync_phase: SyncPhase = .globals,
ready: bool = false,

pub fn initFd(
    self: *Client,
    allocator: std.mem.Allocator,
    fd: i32,
    loop: *IoUringLoop,
    notify_context: *anyopaque,
    notify: Notify,
    message_notify: MessageNotify,
) !void {
    try self.initBase(allocator, loop, notify_context, notify, message_notify);
    errdefer self.connection.deinit();
    try self.transport.init(fd, loop, &self.connection, self, transportNotify);
}

pub fn initConnect(
    self: *Client,
    allocator: std.mem.Allocator,
    path: []const u8,
    loop: *IoUringLoop,
    notify_context: *anyopaque,
    notify: Notify,
    message_notify: MessageNotify,
) !void {
    try self.initBase(allocator, loop, notify_context, notify, message_notify);
    errdefer self.connection.deinit();
    try self.transport.initConnect(path, loop, &self.connection, self, transportNotify);
}

fn initBase(
    self: *Client,
    allocator: std.mem.Allocator,
    loop: *IoUringLoop,
    notify_context: *anyopaque,
    notify: Notify,
    message_notify: MessageNotify,
) !void {
    self.* = .{
        .allocator = allocator,
        .loop = loop,
        .connection = wayring.Connection.init(allocator, .client, wayring.default_max_frame_size),
        .transport = undefined,
        .notify_context = notify_context,
        .notify = notify,
        .message_notify = message_notify,
        .display = undefined,
        .registry = undefined,
        .sync_callback = null,
    };
    errdefer self.connection.deinit();
    self.display = .{
        .id = 1,
        .generation = try self.connection.registerObject(1, &protocol.wl_display, 1),
    };
    self.registry = try protocol.wl_display_types.requests.get_registry(&self.connection, self.display);
    self.sync_callback = try protocol.wl_display_types.requests.sync(&self.connection, self.display);
}

pub fn flush(self: *Client) !void {
    try self.transport.flush();
}

pub fn canSubmitOutputImmediately(self: *const Client) bool {
    return !self.connection.hasPendingOutput() and self.transport.canStartSend();
}

/// Makes queued protocol output visible to the compositor without dispatching
/// completions. Used before bounded synchronous transfers such as clipboard
/// pipe reads.
pub fn submitOutput(self: *Client) !void {
    try self.flush();
    _ = try self.loop.submit();
}

pub fn shutdown(self: *Client) !void {
    try self.transport.shutdown();
}

pub fn readyToDeinit(self: *Client) bool {
    return self.transport.readyToDeinit();
}

pub fn deinit(self: *Client) void {
    self.transport.deinit();
    for (self.outputs.items) |output| if (output.name) |name| self.allocator.free(name);
    self.outputs.deinit(self.allocator);
    self.dmabuf_candidates.deinit(self.allocator);
    self.connection.deinit();
    self.* = undefined;
}

pub fn isReady(self: *const Client) bool {
    return self.ready;
}

pub fn connectionPtr(self: *Client) *wayring.Connection {
    return &self.connection;
}

pub fn displayHandle(self: *const Client) wayring.ObjectHandle {
    return self.display;
}

pub fn dmaBufFactory(self: *const Client) ?wayring.ObjectHandle {
    return if (self.dmabuf) |global| global.handle else null;
}

pub fn dmaBufCandidates(self: *const Client) []const DmaBufCandidate {
    return self.dmabuf_candidates.items;
}

pub fn compositorHandle(self: *const Client) ?wayring.ObjectHandle {
    return if (self.compositor) |global| global.handle else null;
}

pub fn wmBaseHandle(self: *const Client) ?wayring.ObjectHandle {
    return if (self.wm_base) |global| global.handle else null;
}

pub fn shmHandle(self: *const Client) ?wayring.ObjectHandle {
    return if (self.shm) |global| global.handle else null;
}

pub fn takeSeat(self: *Client) ?Seat {
    const seat = self.seat orelse return null;
    std.debug.assert(!self.seat_claimed);
    self.seat_claimed = true;
    return .{ .handle = seat.handle, .capabilities = self.seat_capabilities };
}

pub fn cursorShapeManager(self: *const Client) ?wayring.ObjectHandle {
    return if (self.cursor_shape_manager) |global| global.handle else null;
}

pub fn dataDeviceManager(self: *const Client) ?wayring.ObjectHandle {
    return if (self.data_device_manager) |global| global.handle else null;
}

pub fn activationManager(self: *const Client) ?wayring.ObjectHandle {
    return if (self.activation) |global| global.handle else null;
}

pub fn layerShell(self: *const Client) ?wayring.ObjectHandle {
    return if (self.layer_shell) |global| global.handle else null;
}

pub fn sessionLockManager(self: *const Client) ?wayring.ObjectHandle {
    return if (self.session_lock_manager) |global| global.handle else null;
}

pub fn outputScale(self: *const Client, object_id: u32) ?u32 {
    for (self.outputs.items) |output| {
        if (output.handle.id == object_id) return output.scale;
    }
    return null;
}

pub fn outputCount(self: *const Client) usize {
    return self.outputs.items.len;
}

pub fn outputAt(self: *const Client, index: usize) wayring.ObjectHandle {
    return self.outputs.items[index].handle;
}

pub fn outputInfoAt(self: *const Client, index: usize) OutputInfo {
    const output = self.outputs.items[index];
    const scale: f32 = @floatFromInt(output.scale);
    return .{
        .name = output.name orelse "",
        .width = @as(f32, @floatFromInt(@max(0, output.mode_width))) / scale,
        .height = @as(f32, @floatFromInt(@max(0, output.mode_height))) / scale,
        .scale = scale,
    };
}

pub fn findOutputByName(self: *const Client, name: []const u8) ?wayring.ObjectHandle {
    for (self.outputs.items) |output| {
        if (output.name) |candidate| if (std.mem.eql(u8, name, candidate)) return output.handle;
    }
    return null;
}

pub fn createSurface(self: *Client) !Surface {
    if (!self.ready) return error.ClientNotReady;
    const compositor = self.compositor orelse return error.MissingCompositor;
    const surface = try protocol.wl_compositor_types.requests.create_surface(
        &self.connection,
        compositor.handle,
    );
    errdefer protocol.wl_surface_types.requests.destroy(&self.connection, surface) catch {};
    const viewport = if (self.viewporter != null and self.fractional_scale_manager != null)
        try protocol.wp_viewporter_types.requests.get_viewport(
            &self.connection,
            self.viewporter.?.handle,
            surface,
        )
    else
        null;
    errdefer if (viewport) |handle|
        protocol.wp_viewport_types.requests.destroy(&self.connection, handle) catch {};
    const fractional_scale = if (viewport != null)
        try protocol.wp_fractional_scale_manager_v1_types.requests.get_fractional_scale(
            &self.connection,
            self.fractional_scale_manager.?.handle,
            surface,
        )
    else
        null;
    return .{
        .surface = surface,
        .viewport = viewport,
        .fractional_scale = fractional_scale,
    };
}

pub fn destroySurface(self: *Client, surface: Surface) void {
    if (surface.fractional_scale) |handle|
        protocol.wp_fractional_scale_v1_types.requests.destroy(&self.connection, handle) catch {};
    if (surface.viewport) |handle|
        protocol.wp_viewport_types.requests.destroy(&self.connection, handle) catch {};
    protocol.wl_surface_types.requests.destroy(&self.connection, surface.surface) catch {};
}

pub fn createXdgWindow(self: *Client, title: []const u8, app_id: []const u8) !Window {
    const wm_base = self.wm_base orelse return error.MissingXdgWmBase;
    const base = try self.createSurface();
    errdefer self.destroySurface(base);
    const xdg_surface = try protocol.xdg_wm_base_types.requests.get_xdg_surface(
        &self.connection,
        wm_base.handle,
        base.surface,
    );
    errdefer protocol.xdg_surface_types.requests.destroy(&self.connection, xdg_surface) catch {};
    const toplevel = try protocol.xdg_surface_types.requests.get_toplevel(
        &self.connection,
        xdg_surface,
    );
    errdefer protocol.xdg_toplevel_types.requests.destroy(&self.connection, toplevel) catch {};
    if (title.len != 0) try protocol.xdg_toplevel_types.requests.set_title(
        &self.connection,
        toplevel,
        title,
    );
    if (app_id.len != 0) try protocol.xdg_toplevel_types.requests.set_app_id(
        &self.connection,
        toplevel,
        app_id,
    );
    try protocol.wl_surface_types.requests.commit(&self.connection, base.surface);
    try self.flush();
    return .{
        .surface = base.surface,
        .xdg_surface = xdg_surface,
        .toplevel = toplevel,
        .viewport = base.viewport,
        .fractional_scale = base.fractional_scale,
    };
}

fn transportNotify(
    context: *anyopaque,
    _: *IoUringTransport,
    notification: IoUringTransport.Notification,
) !void {
    const self: *Client = @ptrCast(@alignCast(context));
    switch (notification) {
        .connected => {},
        .messages => try self.dispatchMessages(),
        .output_drained => {},
        .eof => try self.notify(self.notify_context, self, .eof),
        .fatal => try self.notify(self.notify_context, self, .fatal),
    }
}

fn dispatchMessages(self: *Client) !void {
    while (self.connection.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == self.display.id) {
            try self.handleDisplay(&message);
        } else if (message.object_id == self.registry.id) {
            try self.handleRegistry(&message);
        } else if (self.sync_callback) |callback| {
            if (message.object_id == callback.id) {
                _ = try protocol.wl_callback_types.decodeEvent(
                    &self.connection,
                    callback,
                    &message,
                );
                self.sync_callback = null;
                if (self.compositor == null or self.wm_base == null or
                    (self.dmabuf == null and self.shm == null))
                    return error.MissingRequiredGlobal;
                switch (self.sync_phase) {
                    .globals => {
                        self.sync_phase = .bindings;
                        self.sync_callback = try protocol.wl_display_types.requests.sync(
                            &self.connection,
                            self.display,
                        );
                    },
                    .bindings => {
                        self.ready = true;
                        try self.notify(self.notify_context, self, .ready);
                    },
                }
                continue;
            }
            try self.dispatchApplicationMessage(&message);
        } else {
            try self.dispatchApplicationMessage(&message);
        }
    }
    try self.flush();
}

fn dispatchApplicationMessage(self: *Client, message: *wayring.Message) !void {
    if (self.dmabuf) |global| {
        if (message.object_id == global.handle.id) {
            switch (try protocol.zwp_linux_dmabuf_v1_types.decodeEvent(
                &self.connection,
                global.handle,
                message,
            )) {
                .format => {},
                .modifier => |event| {
                    const candidate: DmaBufCandidate = .{
                        .format = event.format,
                        .modifier = (@as(u64, event.modifier_hi) << 32) | event.modifier_lo,
                    };
                    for (self.dmabuf_candidates.items) |existing| {
                        if (std.meta.eql(existing, candidate)) return;
                    }
                    try self.dmabuf_candidates.append(self.allocator, candidate);
                },
            }
            return;
        }
    }
    if (self.shm) |global| {
        if (message.object_id == global.handle.id) {
            _ = try protocol.wl_shm_types.decodeEvent(
                &self.connection,
                global.handle,
                message,
            );
            return;
        }
    }
    if (self.wm_base) |global| {
        if (message.object_id == global.handle.id) {
            const ping = (try protocol.xdg_wm_base_types.decodeEvent(
                &self.connection,
                global.handle,
                message,
            )).ping;
            try protocol.xdg_wm_base_types.requests.pong(
                &self.connection,
                global.handle,
                ping.serial,
            );
            return;
        }
    }
    for (self.outputs.items) |*output| {
        if (message.object_id != output.handle.id) continue;
        switch (try protocol.wl_output_types.decodeEvent(
            &self.connection,
            output.handle,
            message,
        )) {
            .scale => |event| {
                if (event.factor <= 0) return error.InvalidOutputScale;
                const scale: u32 = @intCast(event.factor);
                if (scale != output.scale) {
                    output.scale = scale;
                    output.dirty = true;
                }
            },
            .mode => |event| {
                if (event.flags & protocol.wl_output_types.mode.current != 0 and
                    (output.mode_width != event.width or output.mode_height != event.height))
                {
                    output.mode_width = event.width;
                    output.mode_height = event.height;
                    output.dirty = true;
                }
            },
            .name => |event| {
                if (output.name == null or !std.mem.eql(u8, output.name.?, event.name)) {
                    const name = try self.allocator.dupe(u8, event.name);
                    if (output.name) |old_name| self.allocator.free(old_name);
                    output.name = name;
                    output.dirty = true;
                }
            },
            .done => {
                if (output.dirty) {
                    output.dirty = false;
                    if (self.ready) try self.notify(self.notify_context, self, .outputs_changed);
                }
            },
            .geometry, .description => {},
        }
        return;
    }
    if (self.seat) |global| {
        if (!self.seat_claimed and message.object_id == global.handle.id) {
            switch (try protocol.wl_seat_types.decodeEvent(
                &self.connection,
                global.handle,
                message,
            )) {
                .capabilities => |event| self.seat_capabilities = event.capabilities,
                .name => {},
            }
            return;
        }
    }
    try self.message_notify(self.notify_context, self, message);
}

fn handleDisplay(self: *Client, message: *const wayring.Message) !void {
    switch (try protocol.wl_display_types.decodeEvent(&self.connection, self.display, message)) {
        .@"error" => return error.WaylandProtocolError,
        .delete_id => |event| try self.connection.releaseClientObjectId(event.id),
    }
}

fn handleRegistry(self: *Client, message: *const wayring.Message) !void {
    switch (try protocol.wl_registry_types.decodeEvent(&self.connection, self.registry, message)) {
        .global => |event| try self.bindGlobal(event.name, event.interface, event.version),
        .global_remove => |event| {
            if ((self.compositor != null and self.compositor.?.name == event.name) or
                (self.wm_base != null and self.wm_base.?.name == event.name) or
                (self.dmabuf != null and self.dmabuf.?.name == event.name))
            {
                return error.RequiredGlobalRemoved;
            }
            if (self.seat != null and self.seat.?.name == event.name) self.seat = null;
            if (self.data_device_manager != null and self.data_device_manager.?.name == event.name)
                self.data_device_manager = null;
            if (self.shm != null and self.shm.?.name == event.name)
                self.shm = null;
            if (self.activation != null and self.activation.?.name == event.name)
                self.activation = null;
            if (self.viewporter != null and self.viewporter.?.name == event.name)
                self.viewporter = null;
            if (self.fractional_scale_manager != null and self.fractional_scale_manager.?.name == event.name)
                self.fractional_scale_manager = null;
            if (self.layer_shell != null and self.layer_shell.?.name == event.name)
                self.layer_shell = null;
            if (self.session_lock_manager != null and self.session_lock_manager.?.name == event.name)
                self.session_lock_manager = null;
            for (self.outputs.items, 0..) |output, index| {
                if (output.global_name != event.name) continue;
                const registered = try self.connection.objectForHandle(
                    output.handle,
                    &protocol.wl_output,
                );
                if (registered.version >= 3) {
                    try protocol.wl_output_types.requests.release(
                        &self.connection,
                        output.handle,
                    );
                } else {
                    // wl_output.release was added in version 3. Older
                    // resources can only be retired locally until disconnect.
                    try self.connection.retireObject(output.handle);
                }
                if (output.name) |name| self.allocator.free(name);
                _ = self.outputs.orderedRemove(index);
                if (self.ready) try self.notify(self.notify_context, self, .outputs_changed);
                break;
            }
        },
    }
}

fn bindGlobal(self: *Client, name: u32, interface_name: []const u8, advertised_version: u32) !void {
    if (std.mem.eql(u8, interface_name, protocol.wl_compositor.name) and self.compositor == null) {
        self.compositor = .{
            .name = name,
            .handle = try self.bind(name, advertised_version, &protocol.wl_compositor, protocol.wl_compositor.version),
        };
    } else if (std.mem.eql(u8, interface_name, protocol.xdg_wm_base.name) and self.wm_base == null) {
        self.wm_base = .{
            .name = name,
            .handle = try self.bind(name, advertised_version, &protocol.xdg_wm_base, protocol.xdg_wm_base.version),
        };
    } else if (std.mem.eql(u8, interface_name, protocol.zwp_linux_dmabuf_v1.name) and self.dmabuf == null) {
        if (advertised_version < 3) return;
        self.dmabuf = .{
            .name = name,
            .handle = try self.bind(name, advertised_version, &protocol.zwp_linux_dmabuf_v1, 3),
        };
    } else if (std.mem.eql(u8, interface_name, protocol.wl_shm.name) and self.shm == null) {
        self.shm = .{
            .name = name,
            .handle = try self.bind(name, advertised_version, &protocol.wl_shm, 1),
        };
    } else if (std.mem.eql(u8, interface_name, protocol.wl_seat.name) and self.seat == null) {
        self.seat = .{
            .name = name,
            .handle = try self.bind(name, advertised_version, &protocol.wl_seat, 8),
        };
    } else if (std.mem.eql(u8, interface_name, protocol.wl_data_device_manager.name) and self.data_device_manager == null) {
        self.data_device_manager = .{
            .name = name,
            .handle = try self.bind(
                name,
                advertised_version,
                &protocol.wl_data_device_manager,
                protocol.wl_data_device_manager.version,
            ),
        };
    } else if (std.mem.eql(u8, interface_name, protocol.wp_cursor_shape_manager_v1.name) and self.cursor_shape_manager == null) {
        self.cursor_shape_manager = .{
            .name = name,
            .handle = try self.bind(
                name,
                advertised_version,
                &protocol.wp_cursor_shape_manager_v1,
                1,
            ),
        };
    } else if (std.mem.eql(u8, interface_name, protocol.xdg_activation_v1.name) and self.activation == null) {
        self.activation = .{
            .name = name,
            .handle = try self.bind(name, advertised_version, &protocol.xdg_activation_v1, 1),
        };
    } else if (std.mem.eql(u8, interface_name, protocol.wp_viewporter.name) and self.viewporter == null) {
        self.viewporter = .{
            .name = name,
            .handle = try self.bind(name, advertised_version, &protocol.wp_viewporter, 1),
        };
    } else if (std.mem.eql(u8, interface_name, protocol.wp_fractional_scale_manager_v1.name) and self.fractional_scale_manager == null) {
        self.fractional_scale_manager = .{
            .name = name,
            .handle = try self.bind(name, advertised_version, &protocol.wp_fractional_scale_manager_v1, 1),
        };
    } else if (std.mem.eql(u8, interface_name, protocol.zwlr_layer_shell_v1.name) and self.layer_shell == null) {
        self.layer_shell = .{
            .name = name,
            .handle = try self.bind(name, advertised_version, &protocol.zwlr_layer_shell_v1, protocol.zwlr_layer_shell_v1.version),
        };
    } else if (std.mem.eql(u8, interface_name, protocol.ext_session_lock_manager_v1.name) and self.session_lock_manager == null) {
        self.session_lock_manager = .{
            .name = name,
            .handle = try self.bind(name, advertised_version, &protocol.ext_session_lock_manager_v1, 1),
        };
    } else if (std.mem.eql(u8, interface_name, protocol.wl_output.name)) {
        try self.outputs.append(self.allocator, .{
            .global_name = name,
            .handle = try self.bind(name, advertised_version, &protocol.wl_output, 4),
        });
    }
}

fn bind(
    self: *Client,
    name: u32,
    advertised_version: u32,
    interface: *const wayring.Interface,
    maximum_version: u32,
) !wayring.ObjectHandle {
    return protocol.wl_registry_types.requests.bind(
        &self.connection,
        self.registry,
        name,
        interface,
        @min(advertised_version, maximum_version),
    );
}

test "io_uring client discovers and binds required globals" {
    const linux = std.os.linux;
    const Context = struct {
        client: *Client,
        server: *IoUringTransport,
        ready: bool = false,
        bind_count: usize = 0,

        fn clientNotify(context: *anyopaque, _: *Client, notification: Notification) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (notification == .outputs_changed) return;
            if (notification != .ready) return;
            self.ready = true;
            if (self.bind_count == 12) {
                try self.client.shutdown();
                try self.server.shutdown();
            }
        }

        fn clientMessage(_: *anyopaque, _: *Client, _: *wayring.Message) !void {
            return error.UnexpectedMessage;
        }

        fn serverNotify(
            context: *anyopaque,
            transport: *IoUringTransport,
            notification: IoUringTransport.Notification,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (notification != .messages) return;
            while (transport.connection.popMessage()) |popped| {
                var message = popped;
                defer message.deinit();
                if (message.object_id == 1) {
                    const display: wayring.ObjectHandle = .{
                        .id = 1,
                        .generation = transport.connection.object(1).?.generation,
                    };
                    switch (try protocol.wl_display_types.decodeRequest(
                        transport.connection,
                        display,
                        &message,
                    )) {
                        .get_registry => |request| {
                            const registry = try registerServerObject(
                                transport.connection,
                                request.registry,
                                &protocol.wl_registry,
                                1,
                            );
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 10 }, .{ .string = protocol.wl_compositor.name }, .{ .uint = 6 },
                            });
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 11 }, .{ .string = protocol.xdg_wm_base.name }, .{ .uint = 6 },
                            });
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 12 }, .{ .string = protocol.zwp_linux_dmabuf_v1.name }, .{ .uint = 4 },
                            });
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 13 }, .{ .string = protocol.wl_seat.name }, .{ .uint = 8 },
                            });
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 14 }, .{ .string = protocol.wl_output.name }, .{ .uint = 4 },
                            });
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 15 }, .{ .string = protocol.wl_data_device_manager.name }, .{ .uint = 4 },
                            });
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 16 }, .{ .string = protocol.xdg_activation_v1.name }, .{ .uint = 1 },
                            });
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 17 }, .{ .string = protocol.wp_viewporter.name }, .{ .uint = 1 },
                            });
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 18 }, .{ .string = protocol.wp_fractional_scale_manager_v1.name }, .{ .uint = 1 },
                            });
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 19 }, .{ .string = protocol.wl_shm.name }, .{ .uint = 1 },
                            });
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 20 }, .{ .string = protocol.zwlr_layer_shell_v1.name }, .{ .uint = 5 },
                            });
                            try transport.connection.queue(registry.id, 0, &.{
                                .{ .uint = 21 }, .{ .string = protocol.ext_session_lock_manager_v1.name }, .{ .uint = 1 },
                            });
                        },
                        .sync => |request| {
                            const callback = try registerServerObject(
                                transport.connection,
                                request.callback,
                                &protocol.wl_callback,
                                1,
                            );
                            try transport.connection.queue(callback.id, 0, &.{.{ .uint = 1 }});
                            try transport.connection.queue(1, 1, &.{.{ .uint = callback.id }});
                        },
                    }
                } else {
                    const object = transport.connection.object(message.object_id).?;
                    if (object.interface != &protocol.wl_registry) return error.UnexpectedRequest;
                    const registry: wayring.ObjectHandle = .{
                        .id = message.object_id,
                        .generation = object.generation,
                    };
                    const request = (try protocol.wl_registry_types.decodeRequest(
                        transport.connection,
                        registry,
                        &message,
                    )).bind;
                    const interface = if (std.mem.eql(u8, request.new_interface.?, protocol.wl_compositor.name))
                        &protocol.wl_compositor
                    else if (std.mem.eql(u8, request.new_interface.?, protocol.xdg_wm_base.name))
                        &protocol.xdg_wm_base
                    else if (std.mem.eql(u8, request.new_interface.?, protocol.zwp_linux_dmabuf_v1.name))
                        &protocol.zwp_linux_dmabuf_v1
                    else if (std.mem.eql(u8, request.new_interface.?, protocol.wl_seat.name))
                        &protocol.wl_seat
                    else if (std.mem.eql(u8, request.new_interface.?, protocol.wl_output.name))
                        &protocol.wl_output
                    else if (std.mem.eql(u8, request.new_interface.?, protocol.wl_data_device_manager.name))
                        &protocol.wl_data_device_manager
                    else if (std.mem.eql(u8, request.new_interface.?, protocol.xdg_activation_v1.name))
                        &protocol.xdg_activation_v1
                    else if (std.mem.eql(u8, request.new_interface.?, protocol.wp_viewporter.name))
                        &protocol.wp_viewporter
                    else if (std.mem.eql(u8, request.new_interface.?, protocol.wp_fractional_scale_manager_v1.name))
                        &protocol.wp_fractional_scale_manager_v1
                    else if (std.mem.eql(u8, request.new_interface.?, protocol.wl_shm.name))
                        &protocol.wl_shm
                    else if (std.mem.eql(u8, request.new_interface.?, protocol.zwlr_layer_shell_v1.name))
                        &protocol.zwlr_layer_shell_v1
                    else if (std.mem.eql(u8, request.new_interface.?, protocol.ext_session_lock_manager_v1.name))
                        &protocol.ext_session_lock_manager_v1
                    else
                        return error.UnexpectedBind;
                    const bound = try registerServerObject(
                        transport.connection,
                        request.id,
                        interface,
                        request.new_version,
                    );
                    if (interface == &protocol.zwp_linux_dmabuf_v1) {
                        try transport.connection.queue(bound.id, 1, &.{
                            .{ .uint = 0x34325241 }, .{ .uint = 0 }, .{ .uint = 7 },
                        });
                    } else if (interface == &protocol.wl_seat) {
                        try transport.connection.queue(bound.id, 0, &.{.{ .uint = protocol.wl_seat_types.capability.pointer |
                            protocol.wl_seat_types.capability.keyboard }});
                    } else if (interface == &protocol.wl_output) {
                        try transport.connection.queue(bound.id, 1, &.{
                            .{ .uint = protocol.wl_output_types.mode.current },
                            .{ .int = 3840 },
                            .{ .int = 2160 },
                            .{ .int = 60000 },
                        });
                        try transport.connection.queue(bound.id, 3, &.{.{ .int = 2 }});
                        try transport.connection.queue(bound.id, 4, &.{.{ .string = "DP-1" }});
                        try transport.connection.queue(bound.id, 2, &.{});
                    } else if (interface == &protocol.wl_shm) {
                        try transport.connection.queue(bound.id, 0, &.{.{
                            .uint = @intFromEnum(protocol.wl_shm_types.format.argb8888),
                        }});
                    }
                    self.bind_count += 1;
                }
            }
            try transport.flush();
            if (self.ready and self.bind_count == 12) {
                try self.client.shutdown();
                try self.server.shutdown();
            }
        }

        fn registerServerObject(
            connection: *wayring.Connection,
            id: u32,
            interface: *const wayring.Interface,
            version: u32,
        ) !wayring.ObjectHandle {
            return .{ .id = id, .generation = try connection.registerObject(id, interface, version) };
        }
    };

    var sockets: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets)) != .SUCCESS)
        return error.SocketPairFailed;
    var sockets_owned = true;
    defer if (sockets_owned) {
        for (sockets) |fd| _ = linux.close(fd);
    };

    var loop = try IoUringLoop.init(std.testing.allocator);
    defer loop.deinit();
    var server_connection = wayring.Connection.init(std.testing.allocator, .server, 4096);
    defer server_connection.deinit();
    _ = try server_connection.registerObject(1, &protocol.wl_display, 1);

    var client: Client = undefined;
    var server: IoUringTransport = undefined;
    var context: Context = .{ .client = &client, .server = &server };
    try client.initFd(
        std.testing.allocator,
        sockets[0],
        &loop,
        &context,
        Context.clientNotify,
        Context.clientMessage,
    );
    try server.init(sockets[1], &loop, &server_connection, &context, Context.serverNotify);
    sockets_owned = false;
    try client.flush();
    while (loop.hasActiveOperations()) try loop.runOnce();

    try std.testing.expect(context.ready);
    try std.testing.expectEqual(@as(usize, 12), context.bind_count);
    try std.testing.expectEqualSlices(DmaBufCandidate, &.{.{
        .format = 0x34325241,
        .modifier = 7,
    }}, client.dmaBufCandidates());
    const seat = client.takeSeat().?;
    try std.testing.expectEqual(
        protocol.wl_seat_types.capability.pointer | protocol.wl_seat_types.capability.keyboard,
        seat.capabilities,
    );
    try std.testing.expectEqual(@as(u32, 2), client.outputScale(client.outputs.items[0].handle.id).?);
    try std.testing.expectEqual(@as(usize, 1), client.outputCount());
    try std.testing.expectEqualStrings("DP-1", client.outputInfoAt(0).name);
    try std.testing.expectEqual(@as(f32, 1920), client.outputInfoAt(0).width);
    try std.testing.expectEqual(client.outputAt(0), client.findOutputByName("DP-1").?);
    try std.testing.expect(client.dataDeviceManager() != null);
    try std.testing.expect(client.activationManager() != null);
    try std.testing.expect(client.viewporter != null);
    try std.testing.expect(client.fractional_scale_manager != null);
    try std.testing.expect(client.shmHandle() != null);
    try std.testing.expect(client.layerShell() != null);
    try std.testing.expect(client.sessionLockManager() != null);
    try std.testing.expect(client.readyToDeinit());
    try std.testing.expect(server.readyToDeinit());
    client.deinit();
    server.deinit();
}

test {
    std.testing.refAllDecls(Client);
}
