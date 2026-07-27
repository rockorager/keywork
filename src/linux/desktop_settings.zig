//! Linux desktop settings from Prefer, with XDG Desktop Portal fallback.

const std = @import("std");
const event_loop = @import("event_loop.zig");
const linux_syscall = @import("syscall.zig");
const SystemdEvent = @import("SystemdEvent.zig");
const systemd = @import("systemd_c");

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
    systemd_event: ?*SystemdEvent,
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

    pub fn init(systemd_event: ?*SystemdEvent) !Client {
        const prefer = PreferClient.init() catch |err| {
            log.debug("prefer varlink unavailable, using portal: {}", .{err});
            const bridge = systemd_event orelse return error.SystemdEventUnavailable;
            return .{
                .backend = .{ .portal = try PortalClient.init(bridge) },
                .systemd_event = systemd_event,
            };
        };
        return .{ .backend = .{ .prefer = prefer }, .systemd_event = systemd_event };
    }

    /// Starts the portal query after this Client has reached its stable
    /// address. sd-bus callbacks retain pointers into the selected backend.
    pub fn startColorSchemeRead(self: *Client) !void {
        switch (self.backend) {
            .prefer => {},
            .portal => |*portal| try portal.start(self),
            .none => return error.DesktopSettingsUnavailable,
        }
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
            .portal => invalid_fd,
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
            .portal => {},
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

                const bridge = self.systemd_event orelse return false;
                const portal = PortalClient.init(bridge) catch |err| {
                    log.warn("desktop settings fallback unavailable: {}", .{err});
                    return false;
                };
                self.backend = .{ .portal = portal };
                self.backend.portal.start(self) catch |err| {
                    log.warn("desktop settings fallback query failed: {}", .{err});
                    self.backend.portal.deinit(self);
                    self.backend = .none;
                    return false;
                };
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

    fn handlePortalSettingChanged(self: *Client, message: *systemd.sd_bus_message) void {
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
    bus: *systemd.sd_bus,
    bridge: *SystemdEvent,
    pending_read: ?*systemd.sd_bus_slot = null,
    signal_match: ?*systemd.sd_bus_slot = null,
    initial_color_scheme: ?ColorScheme = null,
    initial_complete: bool = false,
    attached: bool = false,

    fn init(bridge: *SystemdEvent) !PortalClient {
        var bus: ?*systemd.sd_bus = null;
        try checkSystemd(systemd.sd_bus_open_user(&bus));
        return .{ .bus = bus.?, .bridge = bridge };
    }

    fn deinit(self: *PortalClient, _: *Client) void {
        if (self.pending_read) |slot| _ = systemd.sd_bus_slot_unref(slot);
        if (self.signal_match) |slot| _ = systemd.sd_bus_slot_unref(slot);
        if (self.attached) _ = systemd.sd_bus_detach_event(self.bus);
        _ = systemd.sd_bus_flush_close_unref(self.bus);
        self.pending_read = null;
        self.signal_match = null;
        self.attached = false;
    }

    fn start(self: *PortalClient, client: *Client) !void {
        std.debug.assert(self.signal_match == null);
        try checkSystemd(systemd.sd_bus_add_match(
            self.bus,
            &self.signal_match,
            "type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged'",
            portalSignal,
            client,
        ));
        errdefer {
            _ = systemd.sd_bus_slot_unref(self.signal_match);
            self.signal_match = null;
        }
        try self.sendColorSchemeRead();
    }

    fn installSignalFilter(self: *PortalClient, _: *Client) !void {
        std.debug.assert(!self.attached);
        try checkSystemd(systemd.sd_bus_attach_event(self.bus, self.bridge.sdEvent(), 0));
        self.attached = true;
    }

    /// Send the portal color-scheme query without waiting for the reply,
    /// so the round trip through the session bus overlaps the caller's
    /// window setup. finishColorSchemeRead collects the result.
    fn sendColorSchemeRead(self: *PortalClient) !void {
        var message: ?*systemd.sd_bus_message = null;
        try checkSystemd(systemd.sd_bus_message_new_method_call(
            self.bus,
            &message,
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.Settings",
            "ReadOne",
        ));
        defer _ = systemd.sd_bus_message_unref(message);
        try appendSystemdString(message.?, "org.freedesktop.appearance");
        try appendSystemdString(message.?, "color-scheme");
        try checkSystemd(systemd.sd_bus_call_async(
            self.bus,
            &self.pending_read,
            message,
            initialColorSchemeReply,
            self,
            std.time.us_per_s,
        ));
    }

    fn finishColorSchemeRead(self: *PortalClient) ?ColorScheme {
        if (self.pending_read == null) return null;
        while (!self.initial_complete) {
            const processed = systemd.sd_bus_process(self.bus, null);
            if (processed < 0) break;
            if (processed > 0) continue;
            if (systemd.sd_bus_wait(self.bus, std.time.us_per_s) < 0) break;
        }
        const pending = self.pending_read.?;
        self.pending_read = null;
        _ = systemd.sd_bus_slot_unref(pending);
        return self.initial_color_scheme;
    }
};

fn initialColorSchemeReply(message: ?*systemd.sd_bus_message, user_data: ?*anyopaque, _: [*c]systemd.sd_bus_error) callconv(.c) c_int {
    const self: *PortalClient = @ptrCast(@alignCast(user_data orelse return 0));
    self.initial_complete = true;
    const reply = message orelse return 0;
    self.initial_color_scheme = portalColorScheme(readVariantUint32(reply) orelse return 0);
    return 0;
}

fn portalSignal(message: ?*systemd.sd_bus_message, user_data: ?*anyopaque, _: [*c]systemd.sd_bus_error) callconv(.c) c_int {
    const self: *Client = @ptrCast(@alignCast(user_data orelse return 0));
    self.handlePortalSettingChanged(message orelse return 0);
    return 0;
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

fn portalSettingChanged(message: *systemd.sd_bus_message) ?ColorScheme {
    var namespace_ptr: [*c]const u8 = null;
    if (systemd.sd_bus_message_read_basic(message, systemd.SD_BUS_TYPE_STRING, @ptrCast(&namespace_ptr)) <= 0) return null;
    if (!std.mem.eql(u8, std.mem.span(namespace_ptr), "org.freedesktop.appearance")) return null;

    var key_ptr: [*c]const u8 = null;
    if (systemd.sd_bus_message_read_basic(message, systemd.SD_BUS_TYPE_STRING, @ptrCast(&key_ptr)) <= 0) return null;
    if (!std.mem.eql(u8, std.mem.span(key_ptr), "color-scheme")) return null;

    return portalColorScheme(readVariantUint32(message) orelse return null);
}

fn portalColorScheme(value: u32) ColorScheme {
    return switch (value) {
        1 => .dark,
        2 => .light,
        else => .no_preference,
    };
}

fn checkSystemd(result: c_int) !void {
    if (result < 0) return error.SystemdOperationFailed;
}

fn appendSystemdString(message: *systemd.sd_bus_message, value: [*:0]const u8) !void {
    try checkSystemd(systemd.sd_bus_message_append_basic(message, systemd.SD_BUS_TYPE_STRING, value));
}

fn readVariantUint32(message: *systemd.sd_bus_message) ?u32 {
    if (systemd.sd_bus_message_enter_container(message, systemd.SD_BUS_TYPE_VARIANT, "u") <= 0) return null;
    defer _ = systemd.sd_bus_message_exit_container(message);
    var value: u32 = 0;
    if (systemd.sd_bus_message_read_basic(message, systemd.SD_BUS_TYPE_UINT32, &value) <= 0) return null;
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
