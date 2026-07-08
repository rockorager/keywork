//! Toolkit-relevant settings from the XDG Desktop Portal.

const Self = @This();

const std = @import("std");
const appearance = @import("appearance.zig");
const c = @import("dbus_c");
const DbusAdapter = @import("dbus_adapter.zig");
const event_loop = @import("event_loop.zig");

const log = std.log.scoped(.keywork_desktop_settings);

const portal_name = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const settings_interface = "org.freedesktop.portal.Settings";
const appearance_namespace = "org.freedesktop.appearance";
const color_scheme_key = "color-scheme";

allocator: std.mem.Allocator,
bus: *DbusAdapter,
color_scheme: appearance.ColorScheme = .no_preference,
pending_read: ?*c.DBusPendingCall = null,
filter_installed: bool = false,
change_context: *anyopaque,
change_handler: ChangeHandler,

pub const ChangeHandler = *const fn (context: *anyopaque, color_scheme: appearance.ColorScheme) void;

pub fn create(
    allocator: std.mem.Allocator,
    loop: *event_loop.EventLoop,
    change_context: *anyopaque,
    change_handler: ChangeHandler,
) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .bus = try DbusAdapter.create(allocator, loop),
        .change_context = change_context,
        .change_handler = change_handler,
    };
    errdefer self.bus.destroy();

    if (c.dbus_connection_add_filter(self.bus.raw(), messageFilter, self, null) == 0) return error.OutOfMemory;
    self.filter_installed = true;
    errdefer {
        _ = c.dbus_connection_remove_filter(self.bus.raw(), messageFilter, self);
        self.filter_installed = false;
    }

    if (c.keywork_dbus_bus_add_match(
        self.bus.raw(),
        "type='signal',sender='org.freedesktop.portal.Desktop',path='/org/freedesktop/portal/desktop',interface='org.freedesktop.portal.Settings',member='SettingChanged',arg0='org.freedesktop.appearance'",
    ) == 0) return error.DBusMatchFailed;
    try self.startColorSchemeRead();
    return self;
}

pub fn destroy(self: *Self) void {
    if (self.pending_read) |pending| {
        c.dbus_pending_call_cancel(pending);
        c.dbus_pending_call_unref(pending);
        self.pending_read = null;
    }
    if (self.filter_installed) {
        _ = c.dbus_connection_remove_filter(self.bus.raw(), messageFilter, self);
        self.filter_installed = false;
    }
    self.bus.destroy();
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

pub fn dispatchPending(self: *Self) !void {
    self.bus.dispatchPending();
    if (self.bus.takeError()) |err| return err;
}

fn startColorSchemeRead(self: *Self) !void {
    const message = c.dbus_message_new_method_call(portal_name, portal_path, settings_interface, "ReadOne") orelse return error.OutOfMemory;
    defer c.dbus_message_unref(message);

    var iter: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(message, &iter);
    var namespace: [*:0]const u8 = appearance_namespace;
    try appendBasic(&iter, c.DBUS_TYPE_STRING, &namespace);
    var key: [*:0]const u8 = color_scheme_key;
    try appendBasic(&iter, c.DBUS_TYPE_STRING, &key);

    var pending: ?*c.DBusPendingCall = null;
    if (c.dbus_connection_send_with_reply(self.bus.raw(), message, &pending, 1000) == 0) return error.OutOfMemory;
    const call = pending orelse return error.DBusUnavailable;
    self.pending_read = call;
    if (c.dbus_pending_call_set_notify(call, colorSchemeReply, self, null) == 0) {
        self.pending_read = null;
        c.dbus_pending_call_cancel(call);
        c.dbus_pending_call_unref(call);
        return error.OutOfMemory;
    }
}

fn colorSchemeReply(pending_optional: ?*c.DBusPendingCall, data: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(data orelse return));
    const pending = pending_optional orelse return;
    if (self.pending_read == pending) self.pending_read = null;
    const reply = c.dbus_pending_call_steal_reply(pending);
    c.dbus_pending_call_unref(pending);
    const message = reply orelse return;
    defer c.dbus_message_unref(message);

    var iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message, &iter) == 0) return;
    self.updateColorScheme(variantUint32(&iter) orelse return);
}

fn messageFilter(_: ?*c.DBusConnection, message_optional: ?*c.DBusMessage, data: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
    const self: *Self = @ptrCast(@alignCast(data orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
    const message = message_optional orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    if (c.dbus_message_is_signal(message, settings_interface, "SettingChanged") == 0) {
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }
    if (c.dbus_message_has_path(message, portal_path) == 0) return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    self.handleSettingChanged(message);
    return c.DBUS_HANDLER_RESULT_HANDLED;
}

fn handleSettingChanged(self: *Self, message: *c.DBusMessage) void {
    var iter: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(message, &iter) == 0) return;
    if (!iterStringEquals(&iter, appearance_namespace)) return;
    if (c.dbus_message_iter_next(&iter) == 0 or !iterStringEquals(&iter, color_scheme_key)) return;
    if (c.dbus_message_iter_next(&iter) == 0) return;
    self.updateColorScheme(variantUint32(&iter) orelse return);
}

fn updateColorScheme(self: *Self, portal_value: u32) void {
    const value = appearance.fromPortalValue(portal_value) orelse return;
    if (value == self.color_scheme) return;
    self.color_scheme = value;
    log.info("portal color scheme {s}", .{value.name()});
    self.change_handler(self.change_context, value);
}

fn appendBasic(iter: *c.DBusMessageIter, type_: c_int, value: anytype) !void {
    const opaque_value: *const anyopaque = @ptrCast(value);
    if (c.dbus_message_iter_append_basic(iter, type_, opaque_value) == 0) return error.OutOfMemory;
}

fn iterStringEquals(iter: *c.DBusMessageIter, expected: []const u8) bool {
    if (c.dbus_message_iter_get_arg_type(iter) != c.DBUS_TYPE_STRING) return false;
    var value: [*:0]const u8 = undefined;
    c.dbus_message_iter_get_basic(iter, @ptrCast(&value));
    return std.mem.eql(u8, std.mem.span(value), expected);
}

fn variantUint32(iter: *c.DBusMessageIter) ?u32 {
    if (c.dbus_message_iter_get_arg_type(iter) != c.DBUS_TYPE_VARIANT) return null;
    var variant: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(iter, &variant);
    if (c.dbus_message_iter_get_arg_type(&variant) != c.DBUS_TYPE_UINT32) return null;
    var value: u32 = 0;
    c.dbus_message_iter_get_basic(&variant, &value);
    return value;
}
