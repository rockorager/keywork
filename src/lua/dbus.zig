//! Lua D-Bus integration for keywork.dbus.

const std = @import("std");
const event_loop = @import("../linux/event_loop.zig");
const c = @import("luajit_c");
const dbus_c = @import("dbus_c");

const linux = std.os.linux;
const invalid_fd: i32 = -1;

var dbus_temp_z_slot: usize = 0;
var dbus_temp_z_buffers: [8][4096]u8 = undefined;

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allocator: *const fn (*anyopaque) std.mem.Allocator,
        luaState: *const fn (*anyopaque) *c.lua_State,
        eventLoop: *const fn (*anyopaque) ?*event_loop.EventLoop,
        addBus: *const fn (*anyopaque, Kind) anyerror!*Bus,
    };

    fn allocator(self: Host) std.mem.Allocator {
        return self.vtable.allocator(self.ptr);
    }
    fn luaState(self: Host) *c.lua_State {
        return self.vtable.luaState(self.ptr);
    }
    fn eventLoop(self: Host) ?*event_loop.EventLoop {
        return self.vtable.eventLoop(self.ptr);
    }
    fn addBus(self: Host, kind: Kind) !*Bus {
        return self.vtable.addBus(self.ptr, kind);
    }
};

pub const Kind = enum {
    session,
    system,

    fn busType(self: Kind) dbus_c.DBusBusType {
        return switch (self) {
            .session => dbus_c.DBUS_BUS_SESSION,
            .system => dbus_c.DBUS_BUS_SYSTEM,
        };
    }
};

fn hostFromLua(lua_state: *c.lua_State) Host {
    const ptr = c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?;
    return @as(*Host, @ptrCast(@alignCast(ptr))).*;
}

pub fn pushModule(lua_state: *c.lua_State, host: *Host) void {
    c.lua_createtable(lua_state, 0, 16);
    const dbus_table = c.lua_gettop(lua_state);
    c.lua_pushlightuserdata(lua_state, host);
    c.lua_pushcclosure(lua_state, luaDbusSession, 1);
    c.lua_setfield(lua_state, dbus_table, "session");
    c.lua_pushlightuserdata(lua_state, host);
    c.lua_pushcclosure(lua_state, luaDbusSystem, 1);
    c.lua_setfield(lua_state, dbus_table, "system");
    c.lua_pushcclosure(lua_state, luaDbusString, 0);
    c.lua_setfield(lua_state, dbus_table, "string");
    c.lua_pushcclosure(lua_state, luaDbusObjectPath, 0);
    c.lua_setfield(lua_state, dbus_table, "object_path");
    c.lua_pushcclosure(lua_state, luaDbusBoolean, 0);
    c.lua_setfield(lua_state, dbus_table, "boolean");
    c.lua_pushcclosure(lua_state, luaDbusInt32, 0);
    c.lua_setfield(lua_state, dbus_table, "int32");
    c.lua_pushcclosure(lua_state, luaDbusUint32, 0);
    c.lua_setfield(lua_state, dbus_table, "uint32");
    c.lua_pushcclosure(lua_state, luaDbusDouble, 0);
    c.lua_setfield(lua_state, dbus_table, "double");
    c.lua_pushcclosure(lua_state, luaDbusArray, 0);
    c.lua_setfield(lua_state, dbus_table, "array");
    c.lua_pushcclosure(lua_state, luaDbusVariant, 0);
    c.lua_setfield(lua_state, dbus_table, "variant");
}

fn pop(lua_state: *c.lua_State, count: c_int) void {
    c.lua_settop(lua_state, -count - 1);
}
fn absoluteIndex(lua_state: *c.lua_State, index: c_int) c_int {
    if (index > 0 or index <= c.LUA_REGISTRYINDEX) return index;
    return c.lua_gettop(lua_state) + index + 1;
}
fn expectType(lua_state: *c.lua_State, index: c_int, expected: c_int) !void {
    if (c.lua_type(lua_state, index) != expected) return error.UnexpectedLuaType;
}
fn getStringField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) ![]const u8 {
    c.lua_getfield(lua_state, table, key);
    return stringFromStack(lua_state, -1);
}
fn stringField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) ![]const u8 {
    const value = try getStringField(lua_state, table, key);
    defer pop(lua_state, 1);
    return value;
}
fn optionalStringFieldDupe(lua_state: *c.lua_State, allocator: std.mem.Allocator, table: c_int, key: [*:0]const u8) !?[]const u8 {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return null;
    const value = try stringFromStack(lua_state, -1);
    return try allocator.dupe(u8, value);
}
fn getIntegerField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, default: c_int) c_int {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnumber(lua_state, -1) == 0) return default;
    return @intCast(c.lua_tointeger(lua_state, -1));
}
fn boolField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) bool {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    return c.lua_toboolean(lua_state, -1) != 0;
}
fn stringFromStack(lua_state: *c.lua_State, index: c_int) ![]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(lua_state, index, &len) orelse return error.ExpectedLuaString;
    return ptr[0..len];
}

const Subscription = struct {
    bus: *Bus,
    ref: c_int,
    match_rule: ?[:0]const u8 = null,
    sender: ?[]const u8 = null,
    path: ?[]const u8 = null,
    path_namespace: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    canceled: bool = false,

    fn cancel(self: *Subscription, lua_state: *c.lua_State) void {
        if (self.canceled) return;
        self.canceled = true;
        if (self.match_rule) |rule| {
            if (!self.bus.closed) dbus_c.dbus_bus_remove_match(self.bus.connection, rule.ptr, null);
        }
        if (self.ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
            self.ref = -1;
        }
    }

    fn deinit(self: *Subscription, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        if (self.ref >= 0) c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
        if (self.match_rule) |rule| allocator.free(rule);
        if (self.sender) |value| allocator.free(value);
        if (self.path) |value| allocator.free(value);
        if (self.path_namespace) |value| allocator.free(value);
        if (self.interface) |value| allocator.free(value);
        if (self.member) |value| allocator.free(value);
    }

    fn destroy(self: *Subscription, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.deinit(allocator, lua_state);
        allocator.destroy(self);
    }

    fn matches(self: *const Subscription, message: *dbus_c.DBusMessage) bool {
        if (self.canceled or self.ref < 0) return false;
        if (self.sender) |expected| {
            const actual = dbus_c.dbus_message_get_sender(message) orelse return false;
            if (!std.mem.eql(u8, expected, std.mem.span(actual))) return false;
        }
        if (self.interface) |expected| {
            const actual = dbus_c.dbus_message_get_interface(message) orelse return false;
            if (!std.mem.eql(u8, expected, std.mem.span(actual))) return false;
        }
        if (self.member) |expected| {
            const actual = dbus_c.dbus_message_get_member(message) orelse return false;
            if (!std.mem.eql(u8, expected, std.mem.span(actual))) return false;
        }
        if (self.path) |expected| {
            const actual = dbus_c.dbus_message_get_path(message) orelse return false;
            if (!std.mem.eql(u8, expected, std.mem.span(actual))) return false;
        }
        if (self.path_namespace) |expected| {
            const actual = dbus_c.dbus_message_get_path(message) orelse return false;
            if (!std.mem.startsWith(u8, std.mem.span(actual), expected)) return false;
        }
        return true;
    }
};

const OwnedName = struct {
    bus: *Bus,
    name: [:0]const u8,
    released: bool = false,

    fn release(self: *OwnedName) void {
        if (self.released) return;
        self.released = true;
        if (!self.bus.closed) _ = dbus_c.dbus_bus_release_name(self.bus.connection, self.name.ptr, null);
    }

    fn destroy(self: *OwnedName, allocator: std.mem.Allocator) void {
        self.release();
        allocator.free(self.name);
        allocator.destroy(self);
    }
};

const ExportedObject = struct {
    bus: *Bus,
    path: [:0]const u8,
    ref: c_int,
    unexported: bool = false,

    fn unexport(self: *ExportedObject, lua_state: *c.lua_State) void {
        if (self.unexported) return;
        self.unexported = true;
        if (self.ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
            self.ref = -1;
        }
    }

    fn destroy(self: *ExportedObject, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.unexport(lua_state);
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

const Call = struct {
    bus: *Bus,
    ref: c_int = -1,
    pending: ?*dbus_c.DBusPendingCall = null,
    completed: bool = false,

    fn complete(self: *Call) !void {
        if (self.completed) return;
        self.completed = true;

        const lua_state = self.bus.host.luaState();
        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, self.ref);

        const reply = if (self.pending) |pending| dbus_c.dbus_pending_call_steal_reply(pending) else null;
        if (reply) |message| {
            defer dbus_c.dbus_message_unref(message);
            if (dbus_c.dbus_message_get_type(message) == dbus_c.DBUS_MESSAGE_TYPE_ERROR) {
                c.lua_pushnil(lua_state);
                pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_error_name(message));
                if (c.lua_pcall(lua_state, 2, 0, 0) != 0) return failLuaCall(lua_state, "dbus call callback failed");
            } else {
                pushDbusReply(lua_state, message);
                if (c.lua_pcall(lua_state, 1, 0, 0) != 0) return failLuaCall(lua_state, "dbus call callback failed");
            }
        } else {
            c.lua_pushnil(lua_state);
            c.lua_pushliteral(lua_state, "dbus call failed");
            if (c.lua_pcall(lua_state, 2, 0, 0) != 0) return failLuaCall(lua_state, "dbus call callback failed");
        }
    }

    fn deinit(self: *Call, lua_state: *c.lua_State) void {
        if (self.pending) |pending| {
            // Clearing the notify guarantees libdbus never calls back with
            // this soon-to-be-freed state, regardless of cancel semantics.
            _ = dbus_c.dbus_pending_call_set_notify(pending, null, null, null);
            if (!self.completed) dbus_c.dbus_pending_call_cancel(pending);
            dbus_c.dbus_pending_call_unref(pending);
        }
        self.pending = null;
        if (self.ref >= 0) c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
        self.ref = -1;
    }

    fn destroy(self: *Call, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.deinit(lua_state);
        allocator.destroy(self);
    }
};

pub const Bus = struct {
    host: Host,
    kind: Kind,
    connection: *dbus_c.DBusConnection,
    fd: i32,
    subscriptions: std.ArrayList(*Subscription) = .empty,
    pending_calls: std.ArrayList(*Call) = .empty,
    owned_names: std.ArrayList(*OwnedName) = .empty,
    exported_objects: std.ArrayList(*ExportedObject) = .empty,
    registered: bool = false,
    closed: bool = false,
    filter_installed: bool = false,
    source_handle: ?event_loop.EventLoop.SourceHandle = null,

    pub fn create(host: Host, kind: Kind) !*Bus {
        const allocator = host.allocator();
        const bus = try allocator.create(Bus);
        errdefer allocator.destroy(bus);
        bus.* = try Bus.init(host, kind);
        errdefer bus.deinit(allocator, host.luaState());
        try bus.installFilter();
        return bus;
    }

    fn init(host: Host, kind: Kind) !Bus {
        const connection = dbus_c.dbus_bus_get_private(kind.busType(), null) orelse return error.DBusUnavailable;
        errdefer {
            dbus_c.dbus_connection_close(connection);
            dbus_c.dbus_connection_unref(connection);
        }
        dbus_c.dbus_connection_set_exit_on_disconnect(connection, 0);
        var fd: c_int = -1;
        if (dbus_c.dbus_connection_get_unix_fd(connection, &fd) == 0 or fd < 0) return error.DBusUnavailable;
        const self: Bus = .{
            .host = host,
            .kind = kind,
            .connection = connection,
            .fd = @intCast(fd),
        };
        return self;
    }

    fn installFilter(self: *Bus) !void {
        if (self.filter_installed) return;
        if (dbus_c.dbus_connection_add_filter(self.connection, dbusFilter, self, null) == 0) return error.OutOfMemory;
        self.filter_installed = true;
    }

    pub fn register(self: *Bus) !void {
        if (self.registered or self.closed) return;
        const loop = self.host.eventLoop() orelse return;
        self.source_handle = try loop.addFd(.{
            .fd = self.fd,
            .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR,
            .ctx = self,
            .callback = dbusBusCallback,
        });
        errdefer {
            if (self.source_handle) |handle| loop.removeSource(handle);
            self.source_handle = null;
            self.registered = false;
        }
        self.registered = true;
    }

    pub fn unregister(self: *Bus) void {
        if (self.host.eventLoop()) |loop| if (self.source_handle) |handle| loop.removeSource(handle);
        self.source_handle = null;
        self.registered = false;
    }

    pub fn close(self: *Bus) void {
        if (self.closed) return;
        if (self.registered) {
            if (self.host.eventLoop()) |loop| if (self.source_handle) |handle| loop.removeSource(handle);
            self.registered = false;
            self.source_handle = null;
        }
        const lua_state = self.host.luaState();
        for (self.subscriptions.items) |subscription| subscription.cancel(lua_state);
        for (self.owned_names.items) |name| name.release();
        for (self.exported_objects.items) |object| object.unexport(lua_state);

        // A call whose completion callback closes this bus is already on the
        // C stack. Leave that one for dbusCallNotify to remove after the Lua
        // callback returns; all other pending calls can be canceled now.
        var index: usize = 0;
        while (index < self.pending_calls.items.len) {
            const pending_call = self.pending_calls.items[index];
            if (pending_call.completed) {
                index += 1;
                continue;
            }
            _ = self.pending_calls.swapRemove(index);
            pending_call.destroy(self.host.allocator(), lua_state);
        }

        if (self.filter_installed) {
            dbus_c.dbus_connection_remove_filter(self.connection, dbusFilter, self);
            self.filter_installed = false;
        }
        self.closed = true;
        dbus_c.dbus_connection_close(self.connection);
        dbus_c.dbus_connection_unref(self.connection);
        self.fd = invalid_fd;
    }

    fn deinit(self: *Bus, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.close();
        for (self.exported_objects.items) |object| object.destroy(allocator, lua_state);
        self.exported_objects.deinit(allocator);
        for (self.owned_names.items) |name| name.destroy(allocator);
        self.owned_names.deinit(allocator);
        for (self.subscriptions.items) |subscription| subscription.destroy(allocator, lua_state);
        self.subscriptions.deinit(allocator);
        for (self.pending_calls.items) |pending_call| pending_call.destroy(allocator, lua_state);
        self.pending_calls.deinit(allocator);
    }

    pub fn destroy(self: *Bus, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.deinit(allocator, lua_state);
        allocator.destroy(self);
    }

    fn subscribe(self: *Bus, lua_state: *c.lua_State, options_index: c_int, callback_index: c_int) !*Subscription {
        const subscription = try self.host.allocator().create(Subscription);
        errdefer self.host.allocator().destroy(subscription);

        subscription.* = .{
            .bus = self,
            .ref = -1,
            .sender = try optionalStringFieldDupe(lua_state, self.host.allocator(), options_index, "sender"),
            .path = try optionalStringFieldDupe(lua_state, self.host.allocator(), options_index, "path"),
            .path_namespace = try optionalStringFieldDupe(lua_state, self.host.allocator(), options_index, "path_namespace"),
            .interface = try optionalStringFieldDupe(lua_state, self.host.allocator(), options_index, "interface"),
            .member = try optionalStringFieldDupe(lua_state, self.host.allocator(), options_index, "member"),
        };
        errdefer subscription.deinit(self.host.allocator(), lua_state);
        subscription.match_rule = try buildDbusMatchRule(self.host.allocator(), subscription);
        dbus_c.dbus_bus_add_match(self.connection, subscription.match_rule.?.ptr, null);

        c.lua_pushvalue(lua_state, callback_index);
        subscription.ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);

        try self.subscriptions.append(self.host.allocator(), subscription);
        return subscription;
    }

    fn requestName(self: *Bus, lua_state: *c.lua_State, options_index: c_int) !*OwnedName {
        const name = try stringFromStack(lua_state, options_index);
        var flags: c_uint = 0;
        if (c.lua_type(lua_state, options_index + 1) == c.LUA_TTABLE) {
            if (boolField(lua_state, options_index + 1, "allow_replacement")) flags |= 0x1;
            if (boolField(lua_state, options_index + 1, "replace_existing")) flags |= 0x2;
            if (boolField(lua_state, options_index + 1, "do_not_queue")) flags |= 0x4;
        }
        const result = dbus_c.dbus_bus_request_name(self.connection, tryZTemp(name).ptr, flags, null);
        if (result != 1 and result != 4) return error.DBusNameUnavailable;

        const owned = try self.host.allocator().create(OwnedName);
        errdefer self.host.allocator().destroy(owned);
        owned.* = .{
            .bus = self,
            .name = try self.host.allocator().dupeZ(u8, name),
        };
        errdefer self.host.allocator().free(owned.name);
        try self.owned_names.append(self.host.allocator(), owned);
        return owned;
    }

    fn releaseName(self: *Bus, name: []const u8) void {
        for (self.owned_names.items) |owned| {
            if (std.mem.eql(u8, owned.name, name)) {
                owned.release();
                return;
            }
        }
        if (!self.closed) _ = dbus_c.dbus_bus_release_name(self.connection, tryZTemp(name).ptr, null);
    }

    fn exportObject(self: *Bus, lua_state: *c.lua_State, path_index: c_int, spec_index: c_int) !*ExportedObject {
        const path = try stringFromStack(lua_state, path_index);
        try expectType(lua_state, spec_index, c.LUA_TTABLE);
        const object = try self.host.allocator().create(ExportedObject);
        errdefer self.host.allocator().destroy(object);
        c.lua_pushvalue(lua_state, spec_index);
        object.* = .{
            .bus = self,
            .path = try self.host.allocator().dupeZ(u8, path),
            .ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX),
        };
        errdefer object.destroy(self.host.allocator(), lua_state);
        try self.exported_objects.append(self.host.allocator(), object);
        return object;
    }

    fn exportedObjectForPath(self: *Bus, path_z: [*:0]const u8) ?*ExportedObject {
        const path = std.mem.span(path_z);
        for (self.exported_objects.items) |object| {
            if (!object.unexported and std.mem.eql(u8, object.path, path)) return object;
        }
        return null;
    }

    fn call(self: *Bus, lua_state: *c.lua_State, options_index: c_int, callback_index: c_int) !void {
        const destination = try stringField(lua_state, options_index, "destination");
        const path = try stringField(lua_state, options_index, "path");
        const interface = try stringField(lua_state, options_index, "interface");
        const member = try stringField(lua_state, options_index, "member");
        const message = dbus_c.dbus_message_new_method_call(destination.ptr, path.ptr, interface.ptr, member.ptr) orelse return error.OutOfMemory;
        defer dbus_c.dbus_message_unref(message);

        var iter: dbus_c.DBusMessageIter = undefined;
        dbus_c.dbus_message_iter_init_append(message, &iter);
        try appendDbusLuaArgs(lua_state, options_index, &iter);

        const timeout_ms = getIntegerField(lua_state, options_index, "timeout_ms", 1000);
        const call_state = try self.host.allocator().create(Call);
        errdefer self.host.allocator().destroy(call_state);
        c.lua_pushvalue(lua_state, callback_index);
        call_state.* = .{
            .bus = self,
            .ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX),
        };
        errdefer call_state.deinit(lua_state);

        var pending: ?*dbus_c.DBusPendingCall = null;
        if (dbus_c.dbus_connection_send_with_reply(self.connection, message, &pending, @intCast(timeout_ms)) == 0) return error.OutOfMemory;
        call_state.pending = pending orelse return error.DBusCallFailed;

        try self.pending_calls.append(self.host.allocator(), call_state);
        errdefer _ = self.removePendingCall(call_state);
        if (dbus_c.dbus_pending_call_set_notify(call_state.pending, dbusCallNotify, call_state, null) == 0) return error.OutOfMemory;
        dbus_c.dbus_connection_flush(self.connection);
    }

    fn removePendingCall(self: *Bus, pending_call: *Call) bool {
        for (self.pending_calls.items, 0..) |item, index| {
            if (item == pending_call) {
                _ = self.pending_calls.swapRemove(index);
                return true;
            }
        }
        return false;
    }

    fn dispatch(self: *Bus) void {
        _ = dbus_c.dbus_connection_read_write(self.connection, 0);
        while (dbus_c.dbus_connection_dispatch(self.connection) == dbus_c.DBUS_DISPATCH_DATA_REMAINS) {}
    }

    fn emitSignal(self: *Bus, lua_state: *c.lua_State, options_index: c_int) !void {
        const path = try stringField(lua_state, options_index, "path");
        const interface = try stringField(lua_state, options_index, "interface");
        const member = try stringField(lua_state, options_index, "member");
        const message = dbus_c.dbus_message_new_signal(path.ptr, interface.ptr, member.ptr) orelse return error.OutOfMemory;
        defer dbus_c.dbus_message_unref(message);
        var iter: dbus_c.DBusMessageIter = undefined;
        dbus_c.dbus_message_iter_init_append(message, &iter);
        try appendDbusLuaArgs(lua_state, options_index, &iter);
        if (dbus_c.dbus_connection_send(self.connection, message, null) == 0) return error.OutOfMemory;
        dbus_c.dbus_connection_flush(self.connection);
    }

    fn handleSignal(self: *Bus, message: *dbus_c.DBusMessage) !void {
        const lua_state = self.host.luaState();
        for (self.subscriptions.items) |subscription| {
            if (!subscription.matches(message)) continue;
            c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, subscription.ref);
            pushDbusSignal(lua_state, message);
            if (c.lua_pcall(lua_state, 1, 0, 0) != 0) {
                failLuaCall(lua_state, "dbus signal callback failed") catch {};
                return error.LuaCallbackFailed;
            }
        }
    }

    fn handleMethodCall(self: *Bus, message: *dbus_c.DBusMessage) !bool {
        const path_z = dbus_c.dbus_message_get_path(message) orelse return false;
        const object = self.exportedObjectForPath(path_z) orelse return false;
        const interface_z = dbus_c.dbus_message_get_interface(message) orelse return false;
        const member_z = dbus_c.dbus_message_get_member(message) orelse return false;
        const interface = std.mem.span(interface_z);
        const member = std.mem.span(member_z);

        if (std.mem.eql(u8, interface, "org.freedesktop.DBus.Properties")) {
            std.log.scoped(.keywork_luajit).info("dbus properties call {s}.{s}", .{ interface, member });
            try self.handlePropertiesMethod(object, message, member);
            return true;
        }
        if (std.mem.eql(u8, interface, "org.freedesktop.DBus.Introspectable") and std.mem.eql(u8, member, "Introspect")) {
            std.log.scoped(.keywork_luajit).info("dbus introspect {s}", .{object.path});
            const xml = try buildDbusIntrospectionXml(self.host.allocator(), self.host.luaState(), object);
            defer self.host.allocator().free(xml);
            try self.replyString(message, xml);
            return true;
        }
        return try self.callExportedMethod(object, message, interface, member);
    }

    fn callExportedMethod(self: *Bus, object: *ExportedObject, message: *dbus_c.DBusMessage, interface: []const u8, member: []const u8) !bool {
        const lua_state = self.host.luaState();
        const original_top = c.lua_gettop(lua_state);
        defer c.lua_settop(lua_state, original_top);

        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, object.ref);
        c.lua_getfield(lua_state, -1, tryZTemp(interface).ptr);
        if (c.lua_isnil(lua_state, -1)) return false;
        c.lua_getfield(lua_state, -1, "methods");
        if (c.lua_isnil(lua_state, -1)) return false;
        c.lua_getfield(lua_state, -1, tryZTemp(member).ptr);
        if (c.lua_isnil(lua_state, -1)) return false;
        c.lua_getfield(lua_state, -1, "call");
        if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return false;

        std.log.scoped(.keywork_luajit).info("dbus method call {s}.{s}", .{ interface, member });
        pushCallTable(lua_state, message);
        const arg_count = pushDbusMessageArgs(lua_state, message);
        const return_base = c.lua_gettop(lua_state) - @as(c_int, @intCast(arg_count)) - 1;
        if (c.lua_pcall(lua_state, @intCast(arg_count + 1), c.LUA_MULTRET, 0) != 0) {
            const error_message = stringFromStack(lua_state, -1) catch "Lua D-Bus method failed";
            try self.replyError(message, "org.keywork.LuaError", error_message);
            return true;
        }
        const after_top = c.lua_gettop(lua_state);
        const return_count: usize = if (after_top < return_base) 0 else @intCast(after_top - return_base + 1);
        try self.replyValues(message, lua_state, return_base, return_count);
        return true;
    }

    fn handlePropertiesMethod(self: *Bus, object: *ExportedObject, message: *dbus_c.DBusMessage, member: []const u8) !void {
        if (std.mem.eql(u8, member, "Get")) {
            const pair = methodCallStringPair(message) orelse {
                try self.replyError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Get requires interface and property");
                return;
            };
            try self.replyPropertyGet(object, message, pair.interface, pair.property);
        } else if (std.mem.eql(u8, member, "GetAll")) {
            const interface = methodCallString(message, 0) orelse {
                try self.replyError(message, "org.freedesktop.DBus.Error.InvalidArgs", "GetAll requires interface");
                return;
            };
            try self.replyPropertiesGetAll(object, message, interface);
        } else {
            try self.replyError(message, "org.freedesktop.DBus.Error.UnknownMethod", "unsupported Properties method");
        }
    }

    fn replyValues(self: *Bus, message: *dbus_c.DBusMessage, lua_state: *c.lua_State, first_index: c_int, count: usize) !void {
        const reply = dbus_c.dbus_message_new_method_return(message) orelse return error.OutOfMemory;
        defer dbus_c.dbus_message_unref(reply);
        var iter: dbus_c.DBusMessageIter = undefined;
        dbus_c.dbus_message_iter_init_append(reply, &iter);
        var offset: usize = 0;
        while (offset < count) : (offset += 1) {
            const index = first_index + @as(c_int, @intCast(offset));
            if (c.lua_isnil(lua_state, index)) continue;
            try appendLuaValueToDbusIter(lua_state, index, &iter);
        }
        if (dbus_c.dbus_connection_send(self.connection, reply, null) == 0) return error.OutOfMemory;
        dbus_c.dbus_connection_flush(self.connection);
    }

    fn replyString(self: *Bus, message: *dbus_c.DBusMessage, value: []const u8) !void {
        const reply = dbus_c.dbus_message_new_method_return(message) orelse return error.OutOfMemory;
        defer dbus_c.dbus_message_unref(reply);
        var iter: dbus_c.DBusMessageIter = undefined;
        dbus_c.dbus_message_iter_init_append(reply, &iter);
        var value_z = tryZTemp(value);
        try appendDbusBasic(&iter, dbus_c.DBUS_TYPE_STRING, &value_z.ptr);
        if (dbus_c.dbus_connection_send(self.connection, reply, null) == 0) return error.OutOfMemory;
        dbus_c.dbus_connection_flush(self.connection);
    }

    fn replyError(self: *Bus, message: *dbus_c.DBusMessage, name: []const u8, text: []const u8) !void {
        const error_message = dbus_c.dbus_message_new_error(message, tryZTemp(name).ptr, tryZTemp(text).ptr) orelse return error.OutOfMemory;
        defer dbus_c.dbus_message_unref(error_message);
        if (dbus_c.dbus_connection_send(self.connection, error_message, null) == 0) return error.OutOfMemory;
        dbus_c.dbus_connection_flush(self.connection);
    }

    fn replyPropertyGet(self: *Bus, object: *ExportedObject, message: *dbus_c.DBusMessage, interface: []const u8, property: []const u8) !void {
        const lua_state = self.host.luaState();
        const original_top = c.lua_gettop(lua_state);
        defer c.lua_settop(lua_state, original_top);
        try pushPropertyGetterResult(lua_state, object, interface, property);
        const signature = try propertySignature(lua_state, object, interface, property);

        const reply = dbus_c.dbus_message_new_method_return(message) orelse return error.OutOfMemory;
        defer dbus_c.dbus_message_unref(reply);
        var iter: dbus_c.DBusMessageIter = undefined;
        dbus_c.dbus_message_iter_init_append(reply, &iter);
        var variant: dbus_c.DBusMessageIter = undefined;
        if (dbus_c.dbus_message_iter_open_container(&iter, dbus_c.DBUS_TYPE_VARIANT, tryZTemp(signature).ptr, &variant) == 0) return error.OutOfMemory;
        try appendLuaValueWithSignature(lua_state, -1, signature, &variant);
        if (dbus_c.dbus_message_iter_close_container(&iter, &variant) == 0) return error.OutOfMemory;
        if (dbus_c.dbus_connection_send(self.connection, reply, null) == 0) return error.OutOfMemory;
        dbus_c.dbus_connection_flush(self.connection);
    }

    fn replyPropertiesGetAll(self: *Bus, object: *ExportedObject, message: *dbus_c.DBusMessage, interface: []const u8) !void {
        const lua_state = self.host.luaState();
        const original_top = c.lua_gettop(lua_state);
        defer c.lua_settop(lua_state, original_top);

        const reply = dbus_c.dbus_message_new_method_return(message) orelse return error.OutOfMemory;
        defer dbus_c.dbus_message_unref(reply);
        var iter: dbus_c.DBusMessageIter = undefined;
        dbus_c.dbus_message_iter_init_append(reply, &iter);
        var array: dbus_c.DBusMessageIter = undefined;
        if (dbus_c.dbus_message_iter_open_container(&iter, dbus_c.DBUS_TYPE_ARRAY, "{sv}", &array) == 0) return error.OutOfMemory;

        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, object.ref);
        c.lua_getfield(lua_state, -1, tryZTemp(interface).ptr);
        if (!c.lua_isnil(lua_state, -1)) {
            c.lua_getfield(lua_state, -1, "properties");
            if (!c.lua_isnil(lua_state, -1)) {
                c.lua_pushnil(lua_state);
                while (c.lua_next(lua_state, -2) != 0) {
                    if (c.lua_type(lua_state, -2) != c.LUA_TSTRING or c.lua_type(lua_state, -1) != c.LUA_TTABLE) {
                        pop(lua_state, 1);
                        continue;
                    }
                    const property_name = try stringFromStack(lua_state, -2);
                    c.lua_getfield(lua_state, -1, "signature");
                    const signature = stringFromStack(lua_state, -1) catch {
                        pop(lua_state, 1);
                        pop(lua_state, 1);
                        continue;
                    };
                    pop(lua_state, 1);
                    c.lua_getfield(lua_state, -1, "get");
                    if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) {
                        pop(lua_state, 2);
                        continue;
                    }
                    if (c.lua_pcall(lua_state, 0, 1, 0) != 0) {
                        pop(lua_state, 2);
                        continue;
                    }
                    try appendPropertyDictEntry(lua_state, &array, property_name, signature, -1);
                    pop(lua_state, 2);
                }
            }
        }
        if (dbus_c.dbus_message_iter_close_container(&iter, &array) == 0) return error.OutOfMemory;
        if (dbus_c.dbus_connection_send(self.connection, reply, null) == 0) return error.OutOfMemory;
        dbus_c.dbus_connection_flush(self.connection);
    }
};

fn dbusCallNotify(_: ?*dbus_c.DBusPendingCall, user_data: ?*anyopaque) callconv(.c) void {
    const call: *Call = @ptrCast(@alignCast(user_data orelse return));
    call.complete() catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus call callback failed: {}", .{err});
    };
    _ = call.bus.removePendingCall(call);
    call.destroy(call.bus.host.allocator(), call.bus.host.luaState());
}

fn dbusBusCallback(ctx: *anyopaque, _: *event_loop.EventLoop, _: u32) !void {
    const bus: *Bus = @ptrCast(@alignCast(ctx));
    if (bus.closed) return;
    bus.dispatch();
}

fn dbusFilter(_: ?*dbus_c.DBusConnection, message: ?*dbus_c.DBusMessage, user_data: ?*anyopaque) callconv(.c) dbus_c.DBusHandlerResult {
    const bus: *Bus = @ptrCast(@alignCast(user_data orelse return dbus_c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED));
    const msg = message orelse return dbus_c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    switch (dbus_c.dbus_message_get_type(msg)) {
        dbus_c.DBUS_MESSAGE_TYPE_SIGNAL => {
            bus.handleSignal(msg) catch |err| {
                std.log.scoped(.keywork_luajit).warn("dbus signal dispatch failed: {}", .{err});
            };
            return dbus_c.DBUS_HANDLER_RESULT_HANDLED;
        },
        dbus_c.DBUS_MESSAGE_TYPE_METHOD_CALL => {
            const handled = bus.handleMethodCall(msg) catch |err| blk: {
                std.log.scoped(.keywork_luajit).warn("dbus method dispatch failed: {}", .{err});
                break :blk true;
            };
            return if (handled) dbus_c.DBUS_HANDLER_RESULT_HANDLED else dbus_c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        },
        else => return dbus_c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED,
    }
}

fn luaDbusString(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "string", 1);
}

fn luaDbusObjectPath(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "object_path", 1);
}

fn luaDbusBoolean(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "boolean", 1);
}

fn luaDbusInt32(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "int32", 1);
}

fn luaDbusUint32(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "uint32", 1);
}

fn luaDbusDouble(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "double", 1);
}

fn luaDbusArray(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.luaL_checktype(lua_state, 1, c.LUA_TSTRING);
    c.luaL_checktype(lua_state, 2, c.LUA_TTABLE);
    c.lua_createtable(lua_state, 0, 3);
    c.lua_pushliteral(lua_state, "array");
    c.lua_setfield(lua_state, -2, "__dbus_type");
    c.lua_pushvalue(lua_state, 1);
    c.lua_setfield(lua_state, -2, "signature");
    c.lua_pushvalue(lua_state, 2);
    c.lua_setfield(lua_state, -2, "value");
    return 1;
}

fn luaDbusVariant(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.luaL_checktype(lua_state, 1, c.LUA_TSTRING);
    c.lua_createtable(lua_state, 0, 3);
    c.lua_pushliteral(lua_state, "variant");
    c.lua_setfield(lua_state, -2, "__dbus_type");
    c.lua_pushvalue(lua_state, 1);
    c.lua_setfield(lua_state, -2, "signature");
    c.lua_pushvalue(lua_state, 2);
    c.lua_setfield(lua_state, -2, "value");
    return 1;
}

fn pushDbusTypedValue(lua_state: *c.lua_State, comptime type_name: [:0]const u8, value_index: c_int) c_int {
    c.lua_createtable(lua_state, 0, 2);
    c.lua_pushstring(lua_state, type_name.ptr);
    c.lua_setfield(lua_state, -2, "__dbus_type");
    c.lua_pushvalue(lua_state, value_index);
    c.lua_setfield(lua_state, -2, "value");
    return 1;
}

fn luaDbusSession(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return luaBus(lua_state_optional, .session);
}

fn luaDbusSystem(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return luaBus(lua_state_optional, .system);
}

fn luaBus(lua_state_optional: ?*c.lua_State, kind: Kind) c_int {
    const lua_state = lua_state_optional.?;
    const host = hostFromLua(lua_state);
    const bus = host.addBus(kind) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus bus failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus bus failed");
    };
    pushBusHandle(lua_state, bus);
    return 1;
}

fn luaDbusSubscribe(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *Bus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    if (bus.closed) return c.luaL_error(lua_state, "dbus bus is closed");
    const options_index: c_int = if (c.lua_type(lua_state, 3) == c.LUA_TFUNCTION) 2 else 1;
    const callback_index: c_int = options_index + 1;
    c.luaL_checktype(lua_state, options_index, c.LUA_TTABLE);
    c.luaL_checktype(lua_state, callback_index, c.LUA_TFUNCTION);
    const subscription = bus.subscribe(lua_state, options_index, callback_index) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus subscribe failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus subscribe failed");
    };
    pushSubscriptionHandle(lua_state, subscription);
    return 1;
}

fn luaCall(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *Bus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    if (bus.closed) return c.luaL_error(lua_state, "dbus bus is closed");
    const options_index: c_int = if (c.lua_type(lua_state, 3) == c.LUA_TFUNCTION) 2 else 1;
    const callback_index: c_int = options_index + 1;
    c.luaL_checktype(lua_state, options_index, c.LUA_TTABLE);
    c.luaL_checktype(lua_state, callback_index, c.LUA_TFUNCTION);
    bus.call(lua_state, options_index, callback_index) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus call failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus call failed");
    };
    return 0;
}

fn luaDbusRequestName(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *Bus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    if (bus.closed) return c.luaL_error(lua_state, "dbus bus is closed");
    const name_index: c_int = if (c.lua_type(lua_state, 2) == c.LUA_TSTRING) 2 else 1;
    const owned = bus.requestName(lua_state, name_index) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus request_name failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus request_name failed");
    };
    pushOwnedNameHandle(lua_state, owned);
    return 1;
}

fn luaDbusReleaseName(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *Bus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    const name_index: c_int = if (c.lua_type(lua_state, 2) == c.LUA_TSTRING) 2 else 1;
    const name = stringFromStack(lua_state, name_index) catch return c.luaL_error(lua_state, "release_name requires a name");
    bus.releaseName(name);
    return 0;
}

fn luaDbusExport(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *Bus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    if (bus.closed) return c.luaL_error(lua_state, "dbus bus is closed");
    const path_index: c_int = if (c.lua_type(lua_state, 2) == c.LUA_TSTRING) 2 else 1;
    const spec_index = path_index + 1;
    const object = bus.exportObject(lua_state, path_index, spec_index) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus export failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus export failed");
    };
    pushDbusExportHandle(lua_state, object);
    return 1;
}

fn luaDbusEmit(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *Bus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    if (bus.closed) return c.luaL_error(lua_state, "dbus bus is closed");
    const options_index: c_int = if (c.lua_type(lua_state, 2) == c.LUA_TTABLE) 2 else 1;
    bus.emitSignal(lua_state, options_index) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus emit failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus emit failed");
    };
    return 0;
}

fn luaDbusClose(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *Bus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    bus.close();
    return 0;
}

fn luaDbusClosed(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus: *Bus = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    c.lua_pushboolean(lua_state, if (bus.closed) 1 else 0);
    return 1;
}

fn pushBusHandle(lua_state: *c.lua_State, bus: *Bus) void {
    c.lua_createtable(lua_state, 0, 8);
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaDbusSubscribe, 1);
    c.lua_setfield(lua_state, -2, "subscribe");
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaCall, 1);
    c.lua_setfield(lua_state, -2, "call");
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaDbusRequestName, 1);
    c.lua_setfield(lua_state, -2, "request_name");
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaDbusReleaseName, 1);
    c.lua_setfield(lua_state, -2, "release_name");
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaDbusExport, 1);
    c.lua_setfield(lua_state, -2, "export");
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaDbusEmit, 1);
    c.lua_setfield(lua_state, -2, "emit");
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaDbusClose, 1);
    c.lua_setfield(lua_state, -2, "close");
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_pushcclosure(lua_state, luaDbusClosed, 1);
    c.lua_setfield(lua_state, -2, "closed");
}

fn pushSubscriptionHandle(lua_state: *c.lua_State, subscription: *Subscription) void {
    c.lua_createtable(lua_state, 0, 1);
    c.lua_pushlightuserdata(lua_state, subscription);
    c.lua_pushcclosure(lua_state, luaCancelSubscription, 1);
    c.lua_setfield(lua_state, -2, "cancel");
}

fn pushOwnedNameHandle(lua_state: *c.lua_State, owned: *OwnedName) void {
    c.lua_createtable(lua_state, 0, 1);
    c.lua_pushlightuserdata(lua_state, owned);
    c.lua_pushcclosure(lua_state, luaReleaseOwnedName, 1);
    c.lua_setfield(lua_state, -2, "release");
}

fn pushDbusExportHandle(lua_state: *c.lua_State, object: *ExportedObject) void {
    c.lua_createtable(lua_state, 0, 1);
    c.lua_pushlightuserdata(lua_state, object);
    c.lua_pushcclosure(lua_state, luaUnexportDbusObject, 1);
    c.lua_setfield(lua_state, -2, "unexport");
}

fn luaCancelSubscription(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const subscription: *Subscription = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    subscription.cancel(lua_state);
    return 0;
}

fn luaReleaseOwnedName(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const owned: *OwnedName = @ptrCast(@alignCast(c.lua_touserdata(lua_state_optional.?, c.lua_upvalueindex(1)).?));
    owned.release();
    return 0;
}

fn luaUnexportDbusObject(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const object: *ExportedObject = @ptrCast(@alignCast(c.lua_touserdata(lua_state, c.lua_upvalueindex(1)).?));
    object.unexport(lua_state);
    return 0;
}

fn appendDbusLuaArgs(lua_state: *c.lua_State, options_index: c_int, iter: *dbus_c.DBusMessageIter) !void {
    c.lua_getfield(lua_state, options_index, "args");
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return;
    try expectType(lua_state, -1, c.LUA_TTABLE);

    const args_index = absoluteIndex(lua_state, -1);
    var index: c_int = 1;
    while (true) : (index += 1) {
        c.lua_rawgeti(lua_state, args_index, index);
        if (c.lua_isnil(lua_state, -1)) {
            pop(lua_state, 1);
            return;
        }
        const arg_type = c.lua_type(lua_state, -1);
        if (arg_type == c.LUA_TNIL) {
            pop(lua_state, 1);
            return;
        }
        try appendLuaValueToDbusIter(lua_state, -1, iter);
        pop(lua_state, 1);
    }
}

fn appendLuaValueToDbusIter(lua_state: *c.lua_State, index: c_int, iter: *dbus_c.DBusMessageIter) anyerror!void {
    const absolute = absoluteIndex(lua_state, index);
    if (c.lua_type(lua_state, absolute) == c.LUA_TTABLE) {
        c.lua_getfield(lua_state, absolute, "__dbus_type");
        defer pop(lua_state, 1);
        if (!c.lua_isnil(lua_state, -1)) {
            const type_name = try stringFromStack(lua_state, -1);
            if (std.mem.eql(u8, type_name, "string")) return appendTypedField(lua_state, absolute, "s", iter);
            if (std.mem.eql(u8, type_name, "object_path")) return appendTypedField(lua_state, absolute, "o", iter);
            if (std.mem.eql(u8, type_name, "boolean")) return appendTypedField(lua_state, absolute, "b", iter);
            if (std.mem.eql(u8, type_name, "int32")) return appendTypedField(lua_state, absolute, "i", iter);
            if (std.mem.eql(u8, type_name, "uint32")) return appendTypedField(lua_state, absolute, "u", iter);
            if (std.mem.eql(u8, type_name, "double")) return appendTypedField(lua_state, absolute, "d", iter);
            if (std.mem.eql(u8, type_name, "array")) return appendTypedArray(lua_state, absolute, iter);
            if (std.mem.eql(u8, type_name, "variant")) return appendTypedVariant(lua_state, absolute, iter);
            return error.UnsupportedDbusArgument;
        }
    }
    switch (c.lua_type(lua_state, absolute)) {
        c.LUA_TSTRING => try appendLuaValueWithSignature(lua_state, absolute, "s", iter),
        c.LUA_TBOOLEAN => try appendLuaValueWithSignature(lua_state, absolute, "b", iter),
        c.LUA_TNUMBER => try appendLuaValueWithSignature(lua_state, absolute, "d", iter),
        else => return error.UnsupportedDbusArgument,
    }
}

fn appendTypedField(lua_state: *c.lua_State, table: c_int, signature: []const u8, iter: *dbus_c.DBusMessageIter) !void {
    c.lua_getfield(lua_state, table, "value");
    defer pop(lua_state, 1);
    try appendLuaValueWithSignature(lua_state, -1, signature, iter);
}

fn appendTypedArray(lua_state: *c.lua_State, table: c_int, iter: *dbus_c.DBusMessageIter) !void {
    c.lua_getfield(lua_state, table, "signature");
    const signature = try stringFromStack(lua_state, -1);
    defer pop(lua_state, 1);
    c.lua_getfield(lua_state, table, "value");
    defer pop(lua_state, 1);
    try appendArrayWithSignature(lua_state, -1, signature, iter);
}

fn appendTypedVariant(lua_state: *c.lua_State, table: c_int, iter: *dbus_c.DBusMessageIter) !void {
    c.lua_getfield(lua_state, table, "signature");
    const signature = try stringFromStack(lua_state, -1);
    defer pop(lua_state, 1);
    c.lua_getfield(lua_state, table, "value");
    defer pop(lua_state, 1);
    var variant: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_open_container(iter, dbus_c.DBUS_TYPE_VARIANT, tryZTemp(signature).ptr, &variant) == 0) return error.OutOfMemory;
    try appendLuaValueWithSignature(lua_state, -1, signature, &variant);
    if (dbus_c.dbus_message_iter_close_container(iter, &variant) == 0) return error.OutOfMemory;
}

fn appendLuaValueWithSignature(lua_state: *c.lua_State, index: c_int, signature: []const u8, iter: *dbus_c.DBusMessageIter) anyerror!void {
    if (signature.len == 0) return;
    const absolute = absoluteIndex(lua_state, index);
    if (c.lua_type(lua_state, absolute) == c.LUA_TTABLE) {
        c.lua_getfield(lua_state, absolute, "__dbus_type");
        if (!c.lua_isnil(lua_state, -1)) {
            const type_name = try stringFromStack(lua_state, -1);
            pop(lua_state, 1);
            if (std.mem.eql(u8, type_name, "array") or std.mem.eql(u8, type_name, "variant")) return appendLuaValueToDbusIter(lua_state, absolute, iter);
            c.lua_getfield(lua_state, absolute, "value");
            defer pop(lua_state, 1);
            return appendLuaValueWithSignature(lua_state, -1, signature, iter);
        }
        pop(lua_state, 1);
    }
    if (signature[0] == 'a') return appendArrayWithSignature(lua_state, index, signature[1..], iter);
    switch (signature[0]) {
        's' => {
            var value = tryZTemp(try stringFromStack(lua_state, index));
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_STRING, &value.ptr);
        },
        'o' => {
            var value = tryZTemp(try stringFromStack(lua_state, index));
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_OBJECT_PATH, &value.ptr);
        },
        'b' => {
            var value: dbus_c.dbus_bool_t = if (c.lua_toboolean(lua_state, index) != 0) 1 else 0;
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_BOOLEAN, &value);
        },
        'i' => {
            var value: i32 = @intCast(c.lua_tointeger(lua_state, index));
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_INT32, &value);
        },
        'u' => {
            var value: u32 = @intCast(c.lua_tointeger(lua_state, index));
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_UINT32, &value);
        },
        'y' => {
            var value: u8 = @intCast(c.lua_tointeger(lua_state, index));
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_BYTE, &value);
        },
        'n' => {
            var value: i16 = @intCast(c.lua_tointeger(lua_state, index));
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_INT16, &value);
        },
        'q' => {
            var value: u16 = @intCast(c.lua_tointeger(lua_state, index));
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_UINT16, &value);
        },
        'd' => {
            var value: f64 = c.lua_tonumber(lua_state, index);
            try appendDbusBasic(iter, dbus_c.DBUS_TYPE_DOUBLE, &value);
        },
        'v' => try appendLuaValueToDbusIter(lua_state, index, iter),
        else => return error.UnsupportedDbusArgument,
    }
}

fn appendArrayWithSignature(lua_state: *c.lua_State, index: c_int, element_signature: []const u8, iter: *dbus_c.DBusMessageIter) !void {
    try expectType(lua_state, index, c.LUA_TTABLE);
    var array: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_open_container(iter, dbus_c.DBUS_TYPE_ARRAY, tryZTemp(element_signature).ptr, &array) == 0) return error.OutOfMemory;
    const table = absoluteIndex(lua_state, index);
    var item_index: c_int = 1;
    while (true) : (item_index += 1) {
        c.lua_rawgeti(lua_state, table, item_index);
        if (c.lua_isnil(lua_state, -1)) {
            pop(lua_state, 1);
            break;
        }
        try appendLuaValueWithSignature(lua_state, -1, element_signature, &array);
        pop(lua_state, 1);
    }
    if (dbus_c.dbus_message_iter_close_container(iter, &array) == 0) return error.OutOfMemory;
}

fn appendPropertyDictEntry(lua_state: *c.lua_State, array: *dbus_c.DBusMessageIter, name: []const u8, signature: []const u8, value_index: c_int) !void {
    var entry: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_open_container(array, dbus_c.DBUS_TYPE_DICT_ENTRY, null, &entry) == 0) return error.OutOfMemory;
    var name_z = tryZTemp(name);
    try appendDbusBasic(&entry, dbus_c.DBUS_TYPE_STRING, &name_z.ptr);
    var variant: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_open_container(&entry, dbus_c.DBUS_TYPE_VARIANT, tryZTemp(signature).ptr, &variant) == 0) return error.OutOfMemory;
    try appendLuaValueWithSignature(lua_state, value_index, signature, &variant);
    if (dbus_c.dbus_message_iter_close_container(&entry, &variant) == 0) return error.OutOfMemory;
    if (dbus_c.dbus_message_iter_close_container(array, &entry) == 0) return error.OutOfMemory;
}

fn appendDbusBasic(iter: *dbus_c.DBusMessageIter, type_: c_int, value: anytype) !void {
    const opaque_value: *const anyopaque = @ptrCast(value);
    if (dbus_c.dbus_message_iter_append_basic(iter, type_, opaque_value) == 0) return error.OutOfMemory;
}

fn dupeStringFromStack(lua_state: *c.lua_State, allocator: std.mem.Allocator, index: c_int) ![]const u8 {
    const value = try stringFromStack(lua_state, index);
    return try allocator.dupe(u8, value);
}

fn buildDbusMatchRule(allocator: std.mem.Allocator, subscription: *const Subscription) ![:0]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("type='signal'");
    try appendDbusMatchField(&writer.writer, "sender", subscription.sender);
    try appendDbusMatchField(&writer.writer, "path", subscription.path);
    try appendDbusMatchField(&writer.writer, "path_namespace", subscription.path_namespace);
    try appendDbusMatchField(&writer.writer, "interface", subscription.interface);
    try appendDbusMatchField(&writer.writer, "member", subscription.member);
    return try writer.toOwnedSliceSentinel(0);
}

fn appendDbusMatchField(writer: *std.Io.Writer, name: []const u8, value: ?[]const u8) !void {
    const field = value orelse return;
    if (std.mem.indexOfAny(u8, field, "',") != null) return error.InvalidDbusMatchField;
    try writer.print(",{s}='{s}'", .{ name, field });
}

fn pushDbusSignal(lua_state: *c.lua_State, message: *dbus_c.DBusMessage) void {
    c.lua_createtable(lua_state, 0, 6);
    const table = c.lua_gettop(lua_state);
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_sender(message));
    c.lua_setfield(lua_state, table, "sender");
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_path(message));
    c.lua_setfield(lua_state, table, "path");
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_interface(message));
    c.lua_setfield(lua_state, table, "interface");
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_member(message));
    c.lua_setfield(lua_state, table, "member");

    const signature = dbus_c.dbus_message_get_signature(message);
    if (signature) |sig| {
        c.lua_pushstring(lua_state, sig);
    } else {
        c.lua_pushnil(lua_state);
    }
    c.lua_setfield(lua_state, table, "signature");

    pushDbusArgsTable(lua_state, message);
    c.lua_setfield(lua_state, table, "args");
}

fn pushDbusReply(lua_state: *c.lua_State, message: *dbus_c.DBusMessage) void {
    c.lua_createtable(lua_state, 0, 2);
    const table = c.lua_gettop(lua_state);
    const signature = dbus_c.dbus_message_get_signature(message);
    if (signature) |sig| {
        c.lua_pushstring(lua_state, sig);
    } else {
        c.lua_pushnil(lua_state);
    }
    c.lua_setfield(lua_state, table, "signature");

    pushDbusArgsTable(lua_state, message);
    c.lua_setfield(lua_state, table, "args");
}

fn pushCallTable(lua_state: *c.lua_State, message: *dbus_c.DBusMessage) void {
    c.lua_createtable(lua_state, 0, 6);
    const table = c.lua_gettop(lua_state);
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_sender(message));
    c.lua_setfield(lua_state, table, "sender");
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_path(message));
    c.lua_setfield(lua_state, table, "path");
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_interface(message));
    c.lua_setfield(lua_state, table, "interface");
    pushOptionalDbusString(lua_state, dbus_c.dbus_message_get_member(message));
    c.lua_setfield(lua_state, table, "member");
    const serial = dbus_c.dbus_message_get_serial(message);
    c.lua_pushnumber(lua_state, @floatFromInt(serial));
    c.lua_setfield(lua_state, table, "serial");
}

fn pushDbusMessageArgs(lua_state: *c.lua_State, message: *dbus_c.DBusMessage) usize {
    var count: usize = 0;
    var iter: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_init(message, &iter) != 0) {
        while (dbus_c.dbus_message_iter_get_arg_type(&iter) != dbus_c.DBUS_TYPE_INVALID) {
            pushDbusIterValue(lua_state, &iter);
            count += 1;
            if (dbus_c.dbus_message_iter_next(&iter) == 0) break;
        }
    }
    return count;
}

fn methodCallStringPair(message: *dbus_c.DBusMessage) ?struct { interface: []const u8, property: []const u8 } {
    const interface = methodCallString(message, 0) orelse return null;
    const property = methodCallString(message, 1) orelse return null;
    return .{ .interface = interface, .property = property };
}

fn methodCallString(message: *dbus_c.DBusMessage, wanted_index: usize) ?[]const u8 {
    var iter: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_init(message, &iter) == 0) return null;
    var index: usize = 0;
    while (dbus_c.dbus_message_iter_get_arg_type(&iter) != dbus_c.DBUS_TYPE_INVALID) : (index += 1) {
        if (index == wanted_index) {
            if (dbus_c.dbus_message_iter_get_arg_type(&iter) != dbus_c.DBUS_TYPE_STRING) return null;
            var value: [*:0]const u8 = undefined;
            dbus_c.dbus_message_iter_get_basic(&iter, @ptrCast(&value));
            return std.mem.span(value);
        }
        if (dbus_c.dbus_message_iter_next(&iter) == 0) break;
    }
    return null;
}

fn propertySignature(lua_state: *c.lua_State, object: *ExportedObject, interface: []const u8, property: []const u8) ![]const u8 {
    const original_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, original_top);
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, object.ref);
    c.lua_getfield(lua_state, -1, tryZTemp(interface).ptr);
    c.lua_getfield(lua_state, -1, "properties");
    c.lua_getfield(lua_state, -1, tryZTemp(property).ptr);
    c.lua_getfield(lua_state, -1, "signature");
    const signature = try stringFromStack(lua_state, -1);
    return tryZTemp(signature);
}

fn pushPropertyGetterResult(lua_state: *c.lua_State, object: *ExportedObject, interface: []const u8, property: []const u8) !void {
    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, object.ref);
    c.lua_getfield(lua_state, -1, tryZTemp(interface).ptr);
    if (c.lua_isnil(lua_state, -1)) return error.DBusUnknownInterface;
    c.lua_getfield(lua_state, -1, "properties");
    if (c.lua_isnil(lua_state, -1)) return error.DBusUnknownProperty;
    c.lua_getfield(lua_state, -1, tryZTemp(property).ptr);
    if (c.lua_isnil(lua_state, -1)) return error.DBusUnknownProperty;
    c.lua_getfield(lua_state, -1, "get");
    if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.DBusUnreadableProperty;
    if (c.lua_pcall(lua_state, 0, 1, 0) != 0) return error.LuaCallbackFailed;
}

fn buildDbusIntrospectionXml(allocator: std.mem.Allocator, lua_state: *c.lua_State, object: *ExportedObject) ![]u8 {
    const original_top = c.lua_gettop(lua_state);
    defer c.lua_settop(lua_state, original_top);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.writeAll(
        \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
        \\<node>
        \\  <interface name="org.freedesktop.DBus.Introspectable">
        \\    <method name="Introspect">
        \\      <arg name="xml_data" type="s" direction="out"/>
        \\    </method>
        \\  </interface>
        \\  <interface name="org.freedesktop.DBus.Properties">
        \\    <method name="Get">
        \\      <arg name="interface_name" type="s" direction="in"/>
        \\      <arg name="property_name" type="s" direction="in"/>
        \\      <arg name="value" type="v" direction="out"/>
        \\    </method>
        \\    <method name="GetAll">
        \\      <arg name="interface_name" type="s" direction="in"/>
        \\      <arg name="properties" type="a{sv}" direction="out"/>
        \\    </method>
        \\  </interface>
        \\
    );

    c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, object.ref);
    const spec_index = absoluteIndex(lua_state, -1);
    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, spec_index) != 0) {
        if (c.lua_type(lua_state, -2) != c.LUA_TSTRING or c.lua_type(lua_state, -1) != c.LUA_TTABLE) {
            pop(lua_state, 1);
            continue;
        }
        const interface_name = try stringFromStack(lua_state, -2);
        const interface_index = absoluteIndex(lua_state, -1);
        try writer.writer.print("  <interface name=\"{s}\">\n", .{interface_name});
        try writeDbusIntrospectionMethods(&writer.writer, lua_state, interface_index);
        try writeDbusIntrospectionSignals(&writer.writer, lua_state, interface_index);
        try writeDbusIntrospectionProperties(&writer.writer, lua_state, interface_index);
        try writer.writer.writeAll("  </interface>\n");
        pop(lua_state, 1);
    }

    try writer.writer.writeAll("</node>\n");
    return writer.toOwnedSlice();
}

fn writeDbusIntrospectionMethods(writer: *std.Io.Writer, lua_state: *c.lua_State, interface_index: c_int) !void {
    c.lua_getfield(lua_state, interface_index, "methods");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return;
    const methods_index = absoluteIndex(lua_state, -1);
    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, methods_index) != 0) {
        if (c.lua_type(lua_state, -2) != c.LUA_TSTRING or c.lua_type(lua_state, -1) != c.LUA_TTABLE) {
            pop(lua_state, 1);
            continue;
        }
        const method_name = try stringFromStack(lua_state, -2);
        const method_index = absoluteIndex(lua_state, -1);
        try writer.print("    <method name=\"{s}\">\n", .{method_name});
        try writeDbusIntrospectionArgs(writer, lua_state, method_index, "in_signature", "in");
        try writeDbusIntrospectionArgs(writer, lua_state, method_index, "out_signature", "out");
        try writer.writeAll("    </method>\n");
        pop(lua_state, 1);
    }
}

fn writeDbusIntrospectionSignals(writer: *std.Io.Writer, lua_state: *c.lua_State, interface_index: c_int) !void {
    c.lua_getfield(lua_state, interface_index, "signals");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return;
    const signals_index = absoluteIndex(lua_state, -1);
    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, signals_index) != 0) {
        if (c.lua_type(lua_state, -2) != c.LUA_TSTRING or c.lua_type(lua_state, -1) != c.LUA_TTABLE) {
            pop(lua_state, 1);
            continue;
        }
        const signal_name = try stringFromStack(lua_state, -2);
        const signal_index = absoluteIndex(lua_state, -1);
        try writer.print("    <signal name=\"{s}\">\n", .{signal_name});
        try writeDbusIntrospectionArgs(writer, lua_state, signal_index, "signature", null);
        try writer.writeAll("    </signal>\n");
        pop(lua_state, 1);
    }
}

fn writeDbusIntrospectionProperties(writer: *std.Io.Writer, lua_state: *c.lua_State, interface_index: c_int) !void {
    c.lua_getfield(lua_state, interface_index, "properties");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return;
    const properties_index = absoluteIndex(lua_state, -1);
    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, properties_index) != 0) {
        if (c.lua_type(lua_state, -2) != c.LUA_TSTRING or c.lua_type(lua_state, -1) != c.LUA_TTABLE) {
            pop(lua_state, 1);
            continue;
        }
        const property_name = try stringFromStack(lua_state, -2);
        const property_index = absoluteIndex(lua_state, -1);
        c.lua_getfield(lua_state, property_index, "signature");
        const signature = tryZTemp(stringFromStack(lua_state, -1) catch "v");
        pop(lua_state, 1);
        c.lua_getfield(lua_state, property_index, "access");
        const access = tryZTemp(stringFromStack(lua_state, -1) catch "read");
        pop(lua_state, 1);
        try writer.print("    <property name=\"{s}\" type=\"{s}\" access=\"{s}\"/>\n", .{ property_name, signature, access });
        pop(lua_state, 1);
    }
}

fn writeDbusIntrospectionArgs(writer: *std.Io.Writer, lua_state: *c.lua_State, table_index: c_int, key: [:0]const u8, direction: ?[]const u8) !void {
    c.lua_getfield(lua_state, table_index, key.ptr);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return;
    const signature = try stringFromStack(lua_state, -1);
    if (signature.len == 0) return;
    if (direction) |dir| {
        try writer.print("      <arg type=\"{s}\" direction=\"{s}\"/>\n", .{ signature, dir });
    } else {
        try writer.print("      <arg type=\"{s}\"/>\n", .{signature});
    }
}

fn pushDbusArgsTable(lua_state: *c.lua_State, message: *dbus_c.DBusMessage) void {
    c.lua_createtable(lua_state, 0, 0);
    const args_table = c.lua_gettop(lua_state);
    var iter: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_init(message, &iter) != 0) {
        var arg_index: c_int = 1;
        while (dbus_c.dbus_message_iter_get_arg_type(&iter) != dbus_c.DBUS_TYPE_INVALID) : (arg_index += 1) {
            pushDbusIterValue(lua_state, &iter);
            c.lua_rawseti(lua_state, args_table, arg_index);
            if (dbus_c.dbus_message_iter_next(&iter) == 0) break;
        }
    }
}

fn pushOptionalDbusString(lua_state: *c.lua_State, value: ?[*:0]const u8) void {
    if (value) |ptr| {
        c.lua_pushstring(lua_state, ptr);
    } else {
        c.lua_pushnil(lua_state);
    }
}

fn pushDbusIterValue(lua_state: *c.lua_State, iter: *dbus_c.DBusMessageIter) void {
    switch (dbus_c.dbus_message_iter_get_arg_type(iter)) {
        dbus_c.DBUS_TYPE_STRING, dbus_c.DBUS_TYPE_OBJECT_PATH, dbus_c.DBUS_TYPE_SIGNATURE => {
            var value: [*:0]const u8 = undefined;
            dbus_c.dbus_message_iter_get_basic(iter, @ptrCast(&value));
            c.lua_pushstring(lua_state, value);
        },
        dbus_c.DBUS_TYPE_BOOLEAN => {
            var value: dbus_c.dbus_bool_t = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushboolean(lua_state, if (value != 0) 1 else 0);
        },
        dbus_c.DBUS_TYPE_BYTE => {
            var value: u8 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        dbus_c.DBUS_TYPE_INT16 => {
            var value: i16 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        dbus_c.DBUS_TYPE_UINT16 => {
            var value: u16 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        dbus_c.DBUS_TYPE_INT32 => {
            var value: i32 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        dbus_c.DBUS_TYPE_UINT32 => {
            var value: u32 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        dbus_c.DBUS_TYPE_INT64 => {
            var value: i64 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        dbus_c.DBUS_TYPE_UINT64 => {
            var value: u64 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        dbus_c.DBUS_TYPE_DOUBLE => {
            var value: f64 = 0;
            dbus_c.dbus_message_iter_get_basic(iter, &value);
            c.lua_pushnumber(lua_state, value);
        },
        dbus_c.DBUS_TYPE_VARIANT => {
            var child: dbus_c.DBusMessageIter = undefined;
            dbus_c.dbus_message_iter_recurse(iter, &child);
            pushDbusIterValue(lua_state, &child);
        },
        dbus_c.DBUS_TYPE_ARRAY, dbus_c.DBUS_TYPE_STRUCT, dbus_c.DBUS_TYPE_DICT_ENTRY => pushDbusIterSequence(lua_state, iter),
        else => c.lua_pushnil(lua_state),
    }
}

fn pushDbusIterSequence(lua_state: *c.lua_State, iter: *dbus_c.DBusMessageIter) void {
    c.lua_createtable(lua_state, 0, 0);
    const table = c.lua_gettop(lua_state);
    var child: dbus_c.DBusMessageIter = undefined;
    dbus_c.dbus_message_iter_recurse(iter, &child);
    var index: c_int = 1;
    while (dbus_c.dbus_message_iter_get_arg_type(&child) != dbus_c.DBUS_TYPE_INVALID) : (index += 1) {
        pushDbusIterValue(lua_state, &child);
        c.lua_rawseti(lua_state, table, index);
        if (dbus_c.dbus_message_iter_next(&child) == 0) break;
    }
}

fn tableRefField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) !c_int {
    c.lua_getfield(lua_state, table, key);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) {
        pop(lua_state, 1);
        return error.ExpectedLuaTable;
    }
    return c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);
}

fn failLuaCall(lua_state: *c.lua_State, err: []const u8) anyerror {
    var len: usize = 0;
    const message_ptr = c.lua_tolstring(lua_state, -1, &len);
    if (message_ptr) |message| std.log.scoped(.keywork_luajit).warn("{s}: {s}", .{ err, message[0..len] });
    pop(lua_state, 1);
    return error.LuaCallbackFailed;
}

fn tryZTemp(value: []const u8) [:0]const u8 {
    std.debug.assert(value.len < dbus_temp_z_buffers[0].len);
    const slot = dbus_temp_z_slot % dbus_temp_z_buffers.len;
    dbus_temp_z_slot +%= 1;
    @memcpy(dbus_temp_z_buffers[slot][0..value.len], value);
    dbus_temp_z_buffers[slot][value.len] = 0;
    return dbus_temp_z_buffers[slot][0..value.len :0];
}
