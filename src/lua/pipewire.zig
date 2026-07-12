//! PipeWire registry integration for keywork.pipewire.
//!
//! Each connection exposes the server's registry, default metadata, and audio
//! node properties as an asynchronous Lua event stream. Route-aware volume
//! and mute methods write hardware device routes when available, falling back
//! to node properties for virtual devices. The PipeWire loop is nested into
//! Keywork's epoll loop. Realtime scheduling, and its PipeWire helper thread,
//! are disabled unless explicitly requested by the application.

const std = @import("std");
const event_loop = @import("../linux/event_loop.zig");
const lua_coro = @import("coro.zig");
const lua_handle = @import("handle.zig");
const lua_task = @import("task.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");
const pipewire_c = @import("pipewire_c");

const linux = std.os.linux;
const log = std.log.scoped(.keywork_luajit);

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allocator: *const fn (*anyopaque) std.mem.Allocator,
        luaState: *const fn (*anyopaque) *c.lua_State,
        eventLoop: *const fn (*anyopaque) ?*event_loop.EventLoop,
        addConnection: *const fn (*anyopaque, bool) anyerror!*Connection,
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

    fn addConnection(self: Host, realtime: bool) !*Connection {
        return self.vtable.addConnection(self.ptr, realtime);
    }
};

pub const Connection = struct {
    host: Host,
    native: ?*pipewire_c.kw_pw_connection = null,
    stream: lua_coro.Stream = .{},
    handle_ref: c_int = -1,
    source_handle: ?event_loop.EventLoop.SourceHandle = null,
    registered: bool = false,
    closed: bool = false,
    dispatching: bool = false,
    pending_destroy: bool = false,

    pub fn create(host: Host, realtime: bool) !*Connection {
        const allocator = host.allocator();
        const connection = try allocator.create(Connection);
        errdefer allocator.destroy(connection);
        connection.* = .{ .host = host };
        const events: pipewire_c.kw_pw_events = .{
            .global = registryGlobal,
            .global_remove = registryGlobalRemove,
            .metadata = metadataProperty,
            .node_props = nodeProps,
            .node_route = nodeRoute,
            .routes_reset = routesReset,
            .route = routeInfo,
        };
        connection.native = pipewire_c.kw_pw_connection_create(&events, connection, @intFromBool(realtime)) orelse
            return error.PipeWireUnavailable;
        return connection;
    }

    pub fn register(self: *Connection) !void {
        if (self.registered or self.closed) return;
        const loop = self.host.eventLoop() orelse return;
        const native = self.native orelse return error.PipeWireUnavailable;
        const fd = pipewire_c.kw_pw_connection_get_fd(native);
        if (fd < 0) return error.PipeWireUnavailable;

        self.source_handle = try loop.addFd(.{
            .fd = fd,
            .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR,
            .ctx = self,
            .callback = pipewireCallback,
        });
        self.registered = true;
        errdefer self.unregister(loop);
        if (pipewire_c.kw_pw_connection_enter(native) < 0) return error.PipeWireUnavailable;
        try self.dispatch();
    }

    pub fn unregister(self: *Connection, loop: *event_loop.EventLoop) void {
        if (self.source_handle) |handle| loop.removeSource(handle);
        self.source_handle = null;
        self.registered = false;
        // A Lua reader resumed by a PipeWire callback may close this
        // connection before pw_loop_iterate unwinds. Native teardown is
        // already deferred in that case; leaving the loop must be too.
        if (!self.dispatching) {
            if (self.native) |native| pipewire_c.kw_pw_connection_leave(native);
        }
    }

    pub fn cancel(self: *Connection, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        if (self.closed) return;
        self.closed = true;
        if (self.registered) {
            if (self.host.eventLoop()) |loop| self.unregister(loop);
        }
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
        self.stream.cancel(self.host.allocator(), lua_state, mode);
        if (self.dispatching) {
            self.pending_destroy = true;
        } else {
            self.destroyNative();
        }
    }

    pub fn destroy(self: *Connection, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cancel(lua_state, .silent);
        std.debug.assert(!self.dispatching);
        self.destroyNative();
        allocator.destroy(self);
    }

    fn destroyNative(self: *Connection) void {
        const native = self.native orelse return;
        self.native = null;
        self.pending_destroy = false;
        pipewire_c.kw_pw_connection_destroy(native);
    }

    fn dispatch(self: *Connection) !void {
        const native = self.native orelse return;
        std.debug.assert(!self.dispatching);
        self.dispatching = true;
        defer {
            self.dispatching = false;
            if (self.pending_destroy) self.destroyNative();
        }
        if (pipewire_c.kw_pw_connection_iterate(native) < 0) return error.PipeWireDisconnected;
    }
};

pub fn pushModule(lua_state: *c.lua_State, host: *Host) void {
    c.lua_createtable(lua_state, 0, 1);
    c.lua_pushlightuserdata(lua_state, host);
    c.lua_pushcclosure(lua_state, luaConnect, 1);
    c.lua_setfield(lua_state, -2, "connect");
}

fn hostFromLua(lua_state: *c.lua_State) Host {
    return lua_value.upvaluePointer(*Host, lua_state, 1).*;
}

fn pipewireCallback(ctx: *anyopaque, _: *event_loop.EventLoop, _: u32) !void {
    const connection: *Connection = @ptrCast(@alignCast(ctx));
    if (connection.closed) return;
    connection.dispatch() catch |err| {
        log.warn("PipeWire connection closed: {}", .{err});
        connection.cancel(connection.host.luaState(), .resume_reader);
    };
}

fn registryGlobal(
    data: ?*anyopaque,
    id: u32,
    permissions: u32,
    interface_ptr: [*c]const u8,
    version: u32,
    properties: [*c]const pipewire_c.kw_pw_property,
    property_count: u32,
) callconv(.c) void {
    const connection: *Connection = @ptrCast(@alignCast(data.?));
    if (connection.closed) return;
    const lua_state = connection.host.luaState();
    pushGlobalEvent(lua_state, id, permissions, zSpan(interface_ptr), version, properties, property_count);
    connection.stream.deliver(connection.host.allocator(), lua_state) catch |err| {
        log.warn("PipeWire registry delivery failed: {}", .{err});
    };
}

fn registryGlobalRemove(data: ?*anyopaque, id: u32) callconv(.c) void {
    const connection: *Connection = @ptrCast(@alignCast(data.?));
    if (connection.closed) return;
    const lua_state = connection.host.luaState();
    c.lua_createtable(lua_state, 0, 2);
    lua_value.setStringField(lua_state, -1, "type", "global_remove");
    lua_value.setIntegerField(lua_state, -1, "id", id);
    connection.stream.deliver(connection.host.allocator(), lua_state) catch |err| {
        log.warn("PipeWire registry delivery failed: {}", .{err});
    };
}

fn metadataProperty(
    data: ?*anyopaque,
    id: u32,
    subject: u32,
    key: [*c]const u8,
    value_type: [*c]const u8,
    value: [*c]const u8,
) callconv(.c) void {
    const connection: *Connection = @ptrCast(@alignCast(data.?));
    if (connection.closed) return;
    const lua_state = connection.host.luaState();
    c.lua_createtable(lua_state, 0, 6);
    lua_value.setStringField(lua_state, -1, "type", "metadata");
    lua_value.setIntegerField(lua_state, -1, "id", id);
    lua_value.setIntegerField(lua_state, -1, "subject", subject);
    pushOptionalStringField(lua_state, "key", key);
    pushOptionalStringField(lua_state, "value_type", value_type);
    pushOptionalStringField(lua_state, "value", value);
    connection.stream.deliver(connection.host.allocator(), lua_state) catch |err| {
        log.warn("PipeWire metadata delivery failed: {}", .{err});
    };
}

fn nodeProps(
    data: ?*anyopaque,
    id: u32,
    volumes: [*c]const f32,
    volume_count: u32,
    has_mute: c_int,
    muted: c_int,
) callconv(.c) void {
    const connection: *Connection = @ptrCast(@alignCast(data.?));
    if (connection.closed) return;
    const lua_state = connection.host.luaState();
    pushNodePropsEvent(lua_state, id, volumes, volume_count, has_mute != 0, muted != 0);
    connection.stream.deliver(connection.host.allocator(), lua_state) catch |err| {
        log.warn("PipeWire node properties delivery failed: {}", .{err});
    };
}

fn nodeRoute(
    data: ?*anyopaque,
    id: u32,
    device_id: u32,
    route_device: u32,
    route_managed: c_int,
) callconv(.c) void {
    const connection: *Connection = @ptrCast(@alignCast(data.?));
    if (connection.closed) return;
    const lua_state = connection.host.luaState();
    c.lua_createtable(lua_state, 0, 5);
    lua_value.setStringField(lua_state, -1, "type", "node_route");
    lua_value.setIntegerField(lua_state, -1, "id", id);
    lua_value.setIntegerField(lua_state, -1, "device_id", device_id);
    lua_value.setIntegerField(lua_state, -1, "route_device", route_device);
    lua_value.setBooleanField(lua_state, -1, "route_managed", route_managed != 0);
    connection.stream.deliver(connection.host.allocator(), lua_state) catch |err| {
        log.warn("PipeWire node route delivery failed: {}", .{err});
    };
}

fn routeInfo(
    data: ?*anyopaque,
    id: u32,
    device: u32,
    availability: u32,
    port_type: [*c]const u8,
    bus: [*c]const u8,
) callconv(.c) void {
    const connection: *Connection = @ptrCast(@alignCast(data.?));
    if (connection.closed) return;
    const lua_state = connection.host.luaState();
    pushRouteEvent(lua_state, id, device, availability, port_type, bus);
    connection.stream.deliver(connection.host.allocator(), lua_state) catch |err| {
        log.warn("PipeWire route delivery failed: {}", .{err});
    };
}

fn routesReset(data: ?*anyopaque, id: u32) callconv(.c) void {
    const connection: *Connection = @ptrCast(@alignCast(data.?));
    if (connection.closed) return;
    const lua_state = connection.host.luaState();
    c.lua_createtable(lua_state, 0, 2);
    lua_value.setStringField(lua_state, -1, "type", "routes_reset");
    lua_value.setIntegerField(lua_state, -1, "id", id);
    connection.stream.deliver(connection.host.allocator(), lua_state) catch |err| {
        log.warn("PipeWire route reset delivery failed: {}", .{err});
    };
}

fn pushGlobalEvent(
    lua_state: *c.lua_State,
    id: u32,
    permissions: u32,
    interface: []const u8,
    version: u32,
    properties: [*c]const pipewire_c.kw_pw_property,
    property_count: u32,
) void {
    c.lua_createtable(lua_state, 0, 6);
    lua_value.setStringField(lua_state, -1, "type", "global");
    lua_value.setIntegerField(lua_state, -1, "id", id);
    lua_value.setIntegerField(lua_state, -1, "permissions", permissions);
    lua_value.setStringField(lua_state, -1, "interface", interface);
    lua_value.setIntegerField(lua_state, -1, "version", version);

    c.lua_createtable(lua_state, 0, @intCast(property_count));
    if (properties != null) {
        for (properties[0..property_count]) |property| {
            if (property.key == null or property.value == null) continue;
            const key = zSpan(property.key);
            const value = zSpan(property.value);
            c.lua_pushlstring(lua_state, value.ptr, value.len);
            c.lua_setfield(lua_state, -2, key.ptr);
        }
    }
    c.lua_setfield(lua_state, -2, "properties");
}

fn pushNodePropsEvent(
    lua_state: *c.lua_State,
    id: u32,
    volumes: [*c]const f32,
    volume_count: u32,
    has_mute: bool,
    muted: bool,
) void {
    c.lua_createtable(lua_state, 0, 4);
    lua_value.setStringField(lua_state, -1, "type", "node_props");
    lua_value.setIntegerField(lua_state, -1, "id", id);
    c.lua_createtable(lua_state, @intCast(volume_count), 0);
    if (volumes != null) {
        for (volumes[0..volume_count], 1..) |volume, index| {
            c.lua_pushnumber(lua_state, volume);
            c.lua_rawseti(lua_state, -2, @intCast(index));
        }
    }
    c.lua_setfield(lua_state, -2, "channel_volumes");
    if (has_mute) {
        lua_value.setBooleanField(lua_state, -1, "muted", muted);
    }
}

fn pushRouteEvent(
    lua_state: *c.lua_State,
    id: u32,
    device: u32,
    availability: u32,
    port_type: [*c]const u8,
    bus: [*c]const u8,
) void {
    const availability_name: []const u8 = switch (availability) {
        1 => "no",
        2 => "yes",
        else => "unknown",
    };
    c.lua_createtable(lua_state, 0, 6);
    lua_value.setStringField(lua_state, -1, "type", "route");
    lua_value.setIntegerField(lua_state, -1, "id", id);
    lua_value.setIntegerField(lua_state, -1, "device", device);
    lua_value.setStringField(lua_state, -1, "availability", availability_name);
    pushOptionalStringField(lua_state, "port_type", port_type);
    pushOptionalStringField(lua_state, "bus", bus);
}

fn pushOptionalStringField(lua_state: *c.lua_State, name: [*:0]const u8, value: [*c]const u8) void {
    if (value == null) {
        c.lua_pushnil(lua_state);
    } else {
        const text = zSpan(value);
        c.lua_pushlstring(lua_state, text.ptr, text.len);
    }
    c.lua_setfield(lua_state, -2, name);
}

fn zSpan(ptr: [*c]const u8) []const u8 {
    if (ptr == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
}

const connection_type: [*:0]const u8 = "keywork.pipewire_connection";
const connection_methods = [_]lua_handle.Method{
    .{ .name = "next", .func = luaConnectionNext },
    .{ .name = "events", .func = luaConnectionEvents },
    .{ .name = "set_volume", .func = luaConnectionSetVolume },
    .{ .name = "set_mute", .func = luaConnectionSetMute },
    .{ .name = "set_metadata", .func = luaConnectionSetMetadata },
    .{ .name = "close", .func = luaConnectionClose },
    .{ .name = "closed", .func = luaConnectionClosed },
};

fn checkRealtimeOption(lua_state: *c.lua_State) bool {
    if (c.lua_isnoneornil(lua_state, 1)) return false;
    c.luaL_checktype(lua_state, 1, c.LUA_TTABLE);
    c.lua_getfield(lua_state, 1, "realtime");
    if (c.lua_isnil(lua_state, -1)) {
        c.lua_settop(lua_state, -2);
        return false;
    }
    if (c.lua_type(lua_state, -1) != c.LUA_TBOOLEAN) {
        _ = c.luaL_argerror(lua_state, 1, "realtime must be a boolean");
        unreachable;
    }
    const realtime = c.lua_toboolean(lua_state, -1) != 0;
    c.lua_settop(lua_state, -2);
    return realtime;
}

fn luaConnect(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const host = hostFromLua(lua_state);
    lua_task.raiseIfCanceled(lua_state);
    const connection = host.addConnection(checkRealtimeOption(lua_state)) catch |err| {
        log.warn("PipeWire connect failed: {}", .{err});
        return lua_value.pushNilError(lua_state, err);
    };
    lua_task.adoptResource(Connection, lua_state, connection);
    connection.handle_ref = lua_handle.create(lua_state, connection_type, &connection_methods, connection);
    return 1;
}

fn luaConnectionNext(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const connection = lua_handle.resource(Connection, lua_state, 1, connection_type) orelse return 0;
    return connection.stream.awaitNext(lua_state, connection.closed);
}

fn luaConnectionEvents(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    _ = c.luaL_checkudata(lua_state, 1, connection_type);
    return lua_coro.pushIterator(lua_state, luaConnectionNext);
}

fn checkedNodeId(lua_state: *c.lua_State) ?u32 {
    const value = c.luaL_checkinteger(lua_state, 2);
    if (value < 0 or value > std.math.maxInt(u32)) {
        _ = c.luaL_argerror(lua_state, 2, "node id is out of range");
        return null;
    }
    return @intCast(value);
}

fn pushOperationResult(lua_state: *c.lua_State, result: c_int) c_int {
    if (result >= 0) {
        c.lua_pushboolean(lua_state, 1);
        return 1;
    }
    c.lua_pushnil(lua_state);
    const message = zSpan(pipewire_c.kw_pw_error_string(result));
    c.lua_pushlstring(lua_state, message.ptr, message.len);
    return 2;
}

fn luaConnectionSetVolume(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const connection = lua_handle.resource(Connection, lua_state, 1, connection_type) orelse return 0;
    const node_id = checkedNodeId(lua_state) orelse return 0;
    const volume = c.luaL_checknumber(lua_state, 3);
    if (!std.math.isFinite(volume) or volume < 0 or volume > 10) {
        return c.luaL_argerror(lua_state, 3, "volume must be between 0 and 10");
    }
    const native = connection.native orelse return 0;
    return pushOperationResult(
        lua_state,
        pipewire_c.kw_pw_connection_set_volume(native, node_id, @floatCast(volume)),
    );
}

fn luaConnectionSetMute(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const connection = lua_handle.resource(Connection, lua_state, 1, connection_type) orelse return 0;
    const node_id = checkedNodeId(lua_state) orelse return 0;
    if (c.lua_type(lua_state, 3) != c.LUA_TBOOLEAN) {
        return c.luaL_argerror(lua_state, 3, "mute must be a boolean");
    }
    const native = connection.native orelse return 0;
    return pushOperationResult(
        lua_state,
        pipewire_c.kw_pw_connection_set_mute(native, node_id, c.lua_toboolean(lua_state, 3)),
    );
}

fn luaConnectionSetMetadata(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const connection = lua_handle.resource(Connection, lua_state, 1, connection_type) orelse return 0;
    const key = c.luaL_checklstring(lua_state, 2, null).?;
    const value_type = c.luaL_checklstring(lua_state, 3, null).?;
    const value = c.luaL_checklstring(lua_state, 4, null).?;
    const native = connection.native orelse return 0;
    return pushOperationResult(
        lua_state,
        pipewire_c.kw_pw_connection_set_metadata(native, key, value_type, value),
    );
}

fn luaConnectionClose(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const connection = lua_handle.resource(Connection, lua_state, 1, connection_type) orelse return 0;
    connection.cancel(lua_state, .resume_reader);
    return 0;
}

fn luaConnectionClosed(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const connection = lua_handle.resource(Connection, lua_state, 1, connection_type) orelse {
        c.lua_pushboolean(lua_state, 1);
        return 1;
    };
    c.lua_pushboolean(lua_state, if (connection.closed) 1 else 0);
    return 1;
}

test "PipeWire global events expose registry properties" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);
    const properties = [_]pipewire_c.kw_pw_property{
        .{ .key = "media.class", .value = "Audio/Sink" },
        .{ .key = "node.name", .value = "test-sink" },
    };

    pushGlobalEvent(lua_state, 42, 7, "PipeWire:Interface:Node", 3, &properties, properties.len);
    c.lua_getfield(lua_state, -1, "type");
    try std.testing.expectEqualStrings("global", zSpan(c.lua_tolstring(lua_state, -1, null).?));
    c.lua_settop(lua_state, -2);
    c.lua_getfield(lua_state, -1, "properties");
    c.lua_getfield(lua_state, -1, "media.class");
    try std.testing.expectEqualStrings("Audio/Sink", zSpan(c.lua_tolstring(lua_state, -1, null).?));
}

test "PipeWire node property events expose channel volumes and mute" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);
    const volumes = [_]f32{ 0.125, 0.5 };

    pushNodePropsEvent(lua_state, 42, &volumes, volumes.len, true, false);
    c.lua_getfield(lua_state, -1, "type");
    try std.testing.expectEqualStrings("node_props", zSpan(c.lua_tolstring(lua_state, -1, null).?));
    c.lua_settop(lua_state, -2);
    c.lua_getfield(lua_state, -1, "channel_volumes");
    c.lua_rawgeti(lua_state, -1, 2);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), c.lua_tonumber(lua_state, -1), 0.0001);
    c.lua_settop(lua_state, -3);
    c.lua_getfield(lua_state, -1, "muted");
    try std.testing.expectEqual(@as(c_int, 0), c.lua_toboolean(lua_state, -1));
}

test "PipeWire route events expose availability and port type" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);

    pushRouteEvent(lua_state, 50, 1, 1, "speaker", "pci");
    c.lua_getfield(lua_state, -1, "type");
    try std.testing.expectEqualStrings("route", zSpan(c.lua_tolstring(lua_state, -1, null).?));
    c.lua_settop(lua_state, -2);
    c.lua_getfield(lua_state, -1, "availability");
    try std.testing.expectEqualStrings("no", zSpan(c.lua_tolstring(lua_state, -1, null).?));
    c.lua_settop(lua_state, -2);
    c.lua_getfield(lua_state, -1, "port_type");
    try std.testing.expectEqualStrings("speaker", zSpan(c.lua_tolstring(lua_state, -1, null).?));
    c.lua_settop(lua_state, -2);
    c.lua_getfield(lua_state, -1, "bus");
    try std.testing.expectEqualStrings("pci", zSpan(c.lua_tolstring(lua_state, -1, null).?));
}

test "PipeWire realtime scheduling is opt-in" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);

    try std.testing.expect(!checkRealtimeOption(lua_state));

    c.lua_createtable(lua_state, 0, 1);
    try std.testing.expect(!checkRealtimeOption(lua_state));
    lua_value.setBooleanField(lua_state, -1, "realtime", true);
    try std.testing.expect(checkRealtimeOption(lua_state));
}
