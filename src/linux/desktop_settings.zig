//! Linux desktop settings from Prefer, with XDG Desktop Portal fallback.

const std = @import("std");
const event_loop = @import("event_loop.zig");
const linux_syscall = @import("syscall.zig");
const c = @import("dbus_c");

const linux = std.os.linux;
const log = std.log.scoped(.keywork_desktop_settings);
const invalid_fd: i32 = -1;

const prefer_socket_relative_path = "varlink/registry/dev.rockorager.Prefer";
const prefer_watch_request =
    "{\"method\":\"dev.rockorager.Prefer.WatchAppearance\",\"parameters\":{},\"more\":true}\x00";
const prefer_initial_timeout_ms = 1000;
const prefer_read_buffer_size = 4096;

pub const ColorScheme = enum {
    no_preference,
    dark,
    light,

    pub fn name(self: ColorScheme) []const u8 {
        return switch (self) {
            .no_preference => "no-preference",
            .dark => "dark",
            .light => "light",
        };
    }
};

pub const Client = struct {
    backend: Backend,
    color_scheme: ColorScheme = .no_preference,
    change_context: ?*anyopaque = null,
    change_handler: ?ChangeHandler = null,
    source_handle: ?event_loop.EventLoop.SourceHandle = null,

    const Backend = union(enum) {
        prefer: PreferClient,
        portal: PortalClient,
        none,
    };

    pub const ChangeHandler = *const fn (ctx: *anyopaque, color_scheme: ColorScheme) void;

    pub fn init() !Client {
        const prefer = PreferClient.init() catch |err| {
            log.debug("prefer varlink unavailable, using portal: {}", .{err});
            return .{ .backend = .{ .portal = try PortalClient.init() } };
        };
        return .{ .backend = .{ .prefer = prefer } };
    }

    pub fn deinit(self: *Client) void {
        switch (self.backend) {
            .prefer => |*prefer| prefer.deinit(),
            .portal => |*portal| portal.deinit(self),
            .none => {},
        }
        self.backend = .none;
    }

    pub fn installSignalFilter(self: *Client) !void {
        switch (self.backend) {
            .prefer => {},
            .portal => |*portal| try portal.installSignalFilter(self),
            .none => return error.DesktopSettingsUnavailable,
        }
    }

    pub fn eventLoopFd(self: *const Client) i32 {
        return switch (self.backend) {
            .prefer => |prefer| prefer.fd,
            .portal => |portal| portal.fd,
            .none => invalid_fd,
        };
    }

    pub fn setEventLoopSource(self: *Client, handle: event_loop.EventLoop.SourceHandle) void {
        std.debug.assert(self.source_handle == null);
        self.source_handle = handle;
    }

    pub fn setChangeHandler(self: *Client, context: *anyopaque, handler: ChangeHandler) void {
        self.change_context = context;
        self.change_handler = handler;
    }

    pub fn eventLoopCallback(ctx: *anyopaque, loop: *event_loop.EventLoop, _: u32) !void {
        const self: *Client = @ptrCast(@alignCast(ctx));
        switch (self.backend) {
            .prefer => |*prefer| if (!prefer.dispatch(self)) {
                if (self.source_handle) |handle| loop.removeSource(handle);
                self.source_handle = null;
                prefer.deinit();
            },
            .portal => |*portal| portal.dispatch(),
            .none => {},
        }
    }

    /// Collects the initial color scheme. If Prefer accepted the connection
    /// but did not produce a valid streaming reply, switches to the portal.
    /// Returns false only when neither backend remains usable.
    pub fn finishColorSchemeRead(self: *Client) bool {
        switch (self.backend) {
            .prefer => |*prefer| {
                if (prefer.finishInitial(self)) return true;
                log.warn("prefer varlink did not provide appearance; falling back to portal", .{});
                prefer.deinit();
                self.backend = .none;

                const portal = PortalClient.init() catch |err| {
                    log.warn("desktop settings fallback unavailable: {}", .{err});
                    return false;
                };
                self.backend = .{ .portal = portal };
                if (self.backend.portal.finishColorSchemeRead()) |color_scheme| {
                    self.updateColorScheme(color_scheme, "portal");
                }
                return true;
            },
            .portal => |*portal| {
                if (portal.finishColorSchemeRead()) |color_scheme| {
                    self.updateColorScheme(color_scheme, "portal");
                }
                return true;
            },
            .none => return false,
        }
    }

    fn updateColorScheme(self: *Client, color_scheme: ColorScheme, source: []const u8) void {
        if (self.color_scheme == color_scheme) return;
        self.color_scheme = color_scheme;
        log.info("{s} color scheme {s}", .{ source, color_scheme.name() });
        if (self.change_handler) |handler| handler(self.change_context.?, color_scheme);
    }

    fn handlePortalSettingChanged(self: *Client, message: *c.DBusMessage) void {
        const color_scheme = portalSettingChanged(message) orelse return;
        self.updateColorScheme(color_scheme, "portal");
    }
};

const PreferClient = struct {
    fd: i32,
    read_buffer: [prefer_read_buffer_size]u8 = undefined,
    read_length: usize = 0,
    received_initial: bool = false,

    fn init() !PreferClient {
        const runtime_dir_ptr = std.c.getenv("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory;
        const runtime_dir = std.mem.span(runtime_dir_ptr);
        if (runtime_dir.len == 0) return error.MissingRuntimeDirectory;

        var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
        @memset(&address.path, 0);
        const separator: []const u8 = if (runtime_dir[runtime_dir.len - 1] == '/') "" else "/";
        const path_length = runtime_dir.len + separator.len + prefer_socket_relative_path.len;
        if (path_length >= address.path.len) return error.PathTooLong;
        var path_offset: usize = 0;
        @memcpy(address.path[path_offset..][0..runtime_dir.len], runtime_dir);
        path_offset += runtime_dir.len;
        @memcpy(address.path[path_offset..][0..separator.len], separator);
        path_offset += separator.len;
        @memcpy(address.path[path_offset..][0..prefer_socket_relative_path.len], prefer_socket_relative_path);

        const fd = try linux_syscall.fd(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
        errdefer _ = linux.close(fd);
        const address_length: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path_length + 1);
        while (true) switch (linux.errno(linux.connect(fd, @ptrCast(&address), address_length))) {
            .SUCCESS, .ISCONN => break,
            .INTR => continue,
            .NOENT, .CONNREFUSED => return error.PreferUnavailable,
            .ACCES, .PERM => return error.PreferAccessDenied,
            else => return error.PreferConnectionFailed,
        };

        try writePreferRequest(fd);
        try linux_syscall.setNonblocking(fd);
        return .{ .fd = fd };
    }

    fn deinit(self: *PreferClient) void {
        if (self.fd == invalid_fd) return;
        _ = linux.close(self.fd);
        self.fd = invalid_fd;
    }

    fn finishInitial(self: *PreferClient, client: *Client) bool {
        while (self.fd != invalid_fd and !self.received_initial) {
            var poll_fds = [_]linux.pollfd{.{
                .fd = self.fd,
                .events = linux.POLL.IN | linux.POLL.HUP,
                .revents = 0,
            }};
            const ready = linux.poll(&poll_fds, 1, prefer_initial_timeout_ms);
            switch (linux.errno(ready)) {
                .SUCCESS => if (ready == 0) return false,
                .INTR => continue,
                else => return false,
            }
            if (!self.dispatch(client)) {
                self.deinit();
                return false;
            }
        }
        return self.received_initial and self.fd != invalid_fd;
    }

    /// Drains all currently available frames. False means the stream can no
    /// longer produce updates; the caller owns event-source removal and close.
    fn dispatch(self: *PreferClient, client: *Client) bool {
        while (self.fd != invalid_fd) {
            if (self.read_length == self.read_buffer.len) {
                log.warn("prefer varlink response exceeded {} bytes", .{self.read_buffer.len});
                return false;
            }

            const destination = self.read_buffer[self.read_length..];
            const result = linux.read(self.fd, destination.ptr, destination.len);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result == 0) {
                        return false;
                    }
                    self.read_length += result;
                    self.consumeFrames(client) catch |err| {
                        log.warn("invalid prefer varlink response: {}", .{err});
                        return false;
                    };
                },
                .AGAIN => return true,
                .INTR => continue,
                else => return false,
            }
        }
        return false;
    }

    fn consumeFrames(self: *PreferClient, client: *Client) !void {
        var consumed: usize = 0;
        while (std.mem.indexOfScalar(u8, self.read_buffer[consumed..self.read_length], 0)) |relative_end| {
            const frame_end = consumed + relative_end;
            const color_scheme = try preferColorScheme(self.read_buffer[consumed..frame_end]);
            client.updateColorScheme(color_scheme, "prefer");
            self.received_initial = true;
            consumed = frame_end + 1;
        }
        if (consumed == 0) return;
        const remaining = self.read_length - consumed;
        @memmove(self.read_buffer[0..remaining], self.read_buffer[consumed..self.read_length]);
        self.read_length = remaining;
    }
};

const PortalClient = struct {
    connection: *c.DBusConnection,
    fd: i32,
    pending_read: ?*c.DBusPendingCall = null,
    filter_installed: bool = false,

    fn init() !PortalClient {
        const connection = c.dbus_bus_get_private(c.DBUS_BUS_SESSION, null) orelse return error.DBusUnavailable;
        errdefer {
            c.dbus_connection_close(connection);
            c.dbus_connection_unref(connection);
        }

        c.dbus_bus_add_match(connection, "type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged'", null);

        var fd: c_int = -1;
        if (c.dbus_connection_get_unix_fd(connection, &fd) == 0 or fd < 0) return error.DBusUnavailable;

        var self: PortalClient = .{ .connection = connection, .fd = @intCast(fd) };
        self.sendColorSchemeRead();
        return self;
    }

    fn deinit(self: *PortalClient, client: *Client) void {
        if (self.pending_read) |pending| {
            c.dbus_pending_call_cancel(pending);
            c.dbus_pending_call_unref(pending);
            self.pending_read = null;
        }
        if (self.filter_installed) c.dbus_connection_remove_filter(self.connection, dbusFilter, client);
        c.dbus_connection_close(self.connection);
        c.dbus_connection_unref(self.connection);
        self.fd = invalid_fd;
    }

    fn installSignalFilter(self: *PortalClient, client: *Client) !void {
        std.debug.assert(!self.filter_installed);
        if (c.dbus_connection_add_filter(self.connection, dbusFilter, client, null) == 0) return error.OutOfMemory;
        self.filter_installed = true;
    }

    fn dispatch(self: *PortalClient) void {
        _ = c.dbus_connection_read_write(self.connection, 0);
        while (c.dbus_connection_dispatch(self.connection) == c.DBUS_DISPATCH_DATA_REMAINS) {}
    }

    /// Send the portal color-scheme query without waiting for the reply,
    /// so the round trip through the session bus overlaps the caller's
    /// window setup. finishColorSchemeRead collects the result.
    fn sendColorSchemeRead(self: *PortalClient) void {
        const message = c.dbus_message_new_method_call(
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.Settings",
            "ReadOne",
        ) orelse return;
        defer c.dbus_message_unref(message);

        var iter: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(message, &iter);
        var namespace: [*:0]const u8 = "org.freedesktop.appearance";
        dbusAppendBasic(&iter, c.DBUS_TYPE_STRING, &namespace) catch return;
        var key: [*:0]const u8 = "color-scheme";
        dbusAppendBasic(&iter, c.DBUS_TYPE_STRING, &key) catch return;

        var pending: ?*c.DBusPendingCall = null;
        if (c.dbus_connection_send_with_reply(self.connection, message, &pending, 1000) == 0) return;
        self.pending_read = pending;
        // Push the request onto the wire now; the reply lands while the
        // caller does other setup.
        _ = c.dbus_connection_flush(self.connection);
    }

    fn finishColorSchemeRead(self: *PortalClient) ?ColorScheme {
        const pending = self.pending_read orelse return null;
        self.pending_read = null;
        defer c.dbus_pending_call_unref(pending);

        c.dbus_pending_call_block(pending);
        const reply = c.dbus_pending_call_steal_reply(pending) orelse return null;
        defer c.dbus_message_unref(reply);
        if (c.dbus_message_get_type(reply) != c.DBUS_MESSAGE_TYPE_METHOD_RETURN) return null;

        var reply_iter: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(reply, &reply_iter) == 0) return null;
        return portalColorScheme(dbusVariantUint32(&reply_iter) orelse return null);
    }
};

fn dbusFilter(_: ?*c.DBusConnection, message: ?*c.DBusMessage, user_data: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
    const self: *Client = @ptrCast(@alignCast(user_data orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
    const msg = message orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    if (c.dbus_message_is_signal(msg, "org.freedesktop.portal.Settings", "SettingChanged") != 0) {
        self.handlePortalSettingChanged(msg);
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }
    return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

fn writePreferRequest(fd: i32) !void {
    var written: usize = 0;
    while (written < prefer_watch_request.len) {
        const result = linux.sendto(
            fd,
            prefer_watch_request.ptr + written,
            prefer_watch_request.len - written,
            linux.MSG.NOSIGNAL,
            null,
            0,
        );
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.PreferWriteFailed;
                written += result;
            },
            .INTR => continue,
            else => return error.PreferWriteFailed,
        }
    }
}

fn preferColorScheme(response: []const u8) !ColorScheme {
    const Response = struct {
        parameters: struct {
            appearance: struct {
                colorScheme: []const u8,
            },
        },
        continues: bool,
    };
    const parsed = std.json.parseFromSlice(Response, std.heap.page_allocator, response, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidPreferResponse;
    defer parsed.deinit();
    if (!parsed.value.continues) return error.InvalidPreferResponse;
    return std.meta.stringToEnum(ColorScheme, parsed.value.parameters.appearance.colorScheme) orelse
        error.InvalidPreferResponse;
}

fn portalSettingChanged(message: *c.DBusMessage) ?ColorScheme {
    var iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message, &iter) == 0) return null;
    if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_STRING) return null;
    var namespace_ptr: [*:0]const u8 = undefined;
    c.dbus_message_iter_get_basic(&iter, @ptrCast(&namespace_ptr));
    if (!std.mem.eql(u8, std.mem.span(namespace_ptr), "org.freedesktop.appearance")) return null;

    if (c.dbus_message_iter_next(&iter) == 0) return null;
    if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_STRING) return null;
    var key_ptr: [*:0]const u8 = undefined;
    c.dbus_message_iter_get_basic(&iter, @ptrCast(&key_ptr));
    if (!std.mem.eql(u8, std.mem.span(key_ptr), "color-scheme")) return null;

    if (c.dbus_message_iter_next(&iter) == 0) return null;
    return portalColorScheme(dbusVariantUint32(&iter) orelse return null);
}

fn portalColorScheme(value: u32) ColorScheme {
    return switch (value) {
        1 => .dark,
        2 => .light,
        else => .no_preference,
    };
}

fn dbusAppendBasic(iter: *c.DBusMessageIter, type_: c_int, value: anytype) !void {
    const opaque_value: *const anyopaque = @ptrCast(value);
    if (c.dbus_message_iter_append_basic(iter, type_, opaque_value) == 0) return error.OutOfMemory;
}

fn dbusVariantUint32(iter: *c.DBusMessageIter) ?u32 {
    if (c.dbus_message_iter_get_arg_type(iter) != c.DBUS_TYPE_VARIANT) return null;
    var variant: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(iter, &variant);
    if (c.dbus_message_iter_get_arg_type(&variant) != c.DBUS_TYPE_UINT32) return null;
    var value: u32 = 0;
    c.dbus_message_iter_get_basic(&variant, &value);
    return value;
}

test "portalColorScheme maps portal values" {
    try std.testing.expectEqual(ColorScheme.no_preference, portalColorScheme(0));
    try std.testing.expectEqual(ColorScheme.dark, portalColorScheme(1));
    try std.testing.expectEqual(ColorScheme.light, portalColorScheme(2));
    try std.testing.expectEqual(ColorScheme.no_preference, portalColorScheme(99));
}

test "preferColorScheme decodes streaming appearance replies" {
    try std.testing.expectEqual(
        ColorScheme.dark,
        try preferColorScheme(
            "{\"parameters\":{\"appearance\":{\"colorScheme\":\"dark\",\"accentColor\":null," ++
                "\"contrast\":\"no_preference\",\"reducedMotion\":\"no_preference\"}},\"continues\":true}",
        ),
    );
    try std.testing.expectError(
        error.InvalidPreferResponse,
        preferColorScheme("{\"parameters\":{\"appearance\":{\"colorScheme\":\"sepia\"}},\"continues\":true}"),
    );
    try std.testing.expectError(
        error.InvalidPreferResponse,
        preferColorScheme("{\"parameters\":{\"appearance\":{\"colorScheme\":\"light\"}}}"),
    );
}
