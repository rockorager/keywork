//! Linux desktop settings from the XDG Desktop Portal.

const std = @import("std");
const event_loop = @import("event_loop.zig");
const c = @import("dbus_c");

const log = std.log.scoped(.keywork_desktop_settings);

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
    connection: *c.DBusConnection,
    fd: i32,
    color_scheme: ColorScheme = .no_preference,
    filter_installed: bool = false,
    change_context: ?*anyopaque = null,
    change_handler: ?ChangeHandler = null,

    pub const ChangeHandler = *const fn (ctx: *anyopaque, color_scheme: ColorScheme) void;

    pub fn init() !Client {
        const connection = c.dbus_bus_get_private(c.DBUS_BUS_SESSION, null) orelse return error.DBusUnavailable;
        errdefer {
            c.dbus_connection_close(connection);
            c.dbus_connection_unref(connection);
        }

        c.dbus_bus_add_match(connection, "type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged'", null);

        var fd: c_int = -1;
        if (c.dbus_connection_get_unix_fd(connection, &fd) == 0 or fd < 0) return error.DBusUnavailable;

        var self: Client = .{ .connection = connection, .fd = @intCast(fd) };
        self.readPortalColorScheme();
        return self;
    }

    pub fn deinit(self: *Client) void {
        if (self.filter_installed) c.dbus_connection_remove_filter(self.connection, dbusFilter, self);
        c.dbus_connection_close(self.connection);
        c.dbus_connection_unref(self.connection);
        self.fd = -1;
    }

    pub fn installSignalFilter(self: *Client) !void {
        std.debug.assert(!self.filter_installed);
        if (c.dbus_connection_add_filter(self.connection, dbusFilter, self, null) == 0) return error.OutOfMemory;
        self.filter_installed = true;
    }

    pub fn eventLoopFd(self: *const Client) i32 {
        return self.fd;
    }

    pub fn setChangeHandler(self: *Client, context: *anyopaque, handler: ChangeHandler) void {
        self.change_context = context;
        self.change_handler = handler;
    }

    pub fn eventLoopCallback(ctx: *anyopaque, _: *event_loop.EventLoop, _: u32) !void {
        const self: *Client = @ptrCast(@alignCast(ctx));
        self.dispatch();
    }

    fn dispatch(self: *Client) void {
        _ = c.dbus_connection_read_write(self.connection, 0);
        while (c.dbus_connection_dispatch(self.connection) == c.DBUS_DISPATCH_DATA_REMAINS) {}
    }

    fn readPortalColorScheme(self: *Client) void {
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

        const reply = c.dbus_connection_send_with_reply_and_block(self.connection, message, 1000, null) orelse return;
        defer c.dbus_message_unref(reply);

        var reply_iter: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(reply, &reply_iter) == 0) return;
        self.color_scheme = portalColorScheme(dbusVariantUint32(&reply_iter) orelse return);
        log.info("portal color scheme {s}", .{self.color_scheme.name()});
    }

    fn handleSettingChanged(self: *Client, message: *c.DBusMessage) void {
        var iter: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(message, &iter) == 0) return;
        if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_STRING) return;
        var namespace_ptr: [*:0]const u8 = undefined;
        c.dbus_message_iter_get_basic(&iter, @ptrCast(&namespace_ptr));
        if (!std.mem.eql(u8, std.mem.span(namespace_ptr), "org.freedesktop.appearance")) return;

        if (c.dbus_message_iter_next(&iter) == 0) return;
        if (c.dbus_message_iter_get_arg_type(&iter) != c.DBUS_TYPE_STRING) return;
        var key_ptr: [*:0]const u8 = undefined;
        c.dbus_message_iter_get_basic(&iter, @ptrCast(&key_ptr));
        if (!std.mem.eql(u8, std.mem.span(key_ptr), "color-scheme")) return;

        if (c.dbus_message_iter_next(&iter) == 0) return;
        const color_scheme = portalColorScheme(dbusVariantUint32(&iter) orelse return);
        if (self.color_scheme == color_scheme) return;
        self.color_scheme = color_scheme;
        log.info("portal color scheme {s}", .{color_scheme.name()});
        if (self.change_handler) |handler| handler(self.change_context.?, color_scheme);
    }
};

fn dbusFilter(_: ?*c.DBusConnection, message: ?*c.DBusMessage, user_data: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
    const self: *Client = @ptrCast(@alignCast(user_data orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
    const msg = message orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    if (c.dbus_message_is_signal(msg, "org.freedesktop.portal.Settings", "SettingChanged") != 0) {
        self.handleSettingChanged(msg);
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }
    return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
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
