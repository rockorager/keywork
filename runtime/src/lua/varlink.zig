//! sd-varlink server integration for keywork.varlink.

const std = @import("std");
const SystemdEvent = @import("keywork-runtime").SystemdEvent;
const lua_coro = @import("coro.zig");
const lua_handle = @import("handle.zig");
const lua_json = @import("json.zig");
const lua_task = @import("task.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");
const systemd = @import("systemd_c");

const log = std.log.scoped(.keywork_varlink);
const embedded_source = @embedFile("varlink.lua");
const dispatch_registry_key: [*:0]const u8 = "keywork.varlink.dispatch";

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allocator: *const fn (*anyopaque) std.mem.Allocator,
        luaState: *const fn (*anyopaque) *c.lua_State,
        systemdEvent: *const fn (*anyopaque) anyerror!*SystemdEvent,
        addServer: *const fn (*anyopaque, ServeOptions) anyerror!*Server,
        addClient: *const fn (*anyopaque, []const u8) anyerror!*Client,
    };

    fn allocator(self: Host) std.mem.Allocator {
        return self.vtable.allocator(self.ptr);
    }

    fn luaState(self: Host) *c.lua_State {
        return self.vtable.luaState(self.ptr);
    }

    fn systemdEvent(self: Host) !*SystemdEvent {
        return try self.vtable.systemdEvent(self.ptr);
    }

    fn addServer(self: Host, options: ServeOptions) !*Server {
        return try self.vtable.addServer(self.ptr, options);
    }

    fn addClient(self: Host, address: []const u8) !*Client {
        return try self.vtable.addClient(self.ptr, address);
    }
};

pub const ServeOptions = struct {
    methods_ref: c_int,
    address: ?[]const u8,
};

pub const Client = struct {
    host: Host,
    native: *systemd.sd_varlink,
    event: *systemd.sd_event,
    handle_ref: c_int = -1,
    requests: std.ArrayList(*Request) = .empty,
    deferred_replies: std.ArrayList(*DeferredReply) = .empty,
    current: ?*Request = null,
    closed: bool = false,

    pub fn create(host: Host, address: []const u8) !*Client {
        const allocator = host.allocator();
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);
        const address_z = try allocator.dupeZ(u8, address);
        defer allocator.free(address_z);
        var native: ?*systemd.sd_varlink = null;
        try checkOperation("connect address", systemd.sd_varlink_connect_address(&native, address_z.ptr));
        errdefer _ = systemd.sd_varlink_unref(native.?);
        const bridge = try host.systemdEvent();
        self.* = .{ .host = host, .native = native.?, .event = bridge.sdEvent() };
        _ = systemd.sd_varlink_set_userdata(self.native, self);
        try check(systemd.sd_varlink_bind_reply(self.native, replyCallback));
        try check(systemd.sd_varlink_attach_event(self.native, bridge.sdEvent(), 0));
        return self;
    }

    pub fn cancel(self: *Client, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        self.close(lua_state, mode);
    }

    pub fn close(self: *Client, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        if (self.closed) return;
        self.closed = true;
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
        if (self.current) |request| request.finish(lua_state, mode);
        while (self.deferred_replies.pop()) |reply| reply.destroy();
        _ = systemd.sd_varlink_close(self.native);
    }

    pub fn destroy(self: *Client, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.close(lua_state, .silent);
        for (self.requests.items) |request| request.destroy(allocator, lua_state);
        self.requests.deinit(allocator);
        self.deferred_replies.deinit(allocator);
        systemd.sd_varlink_detach_event(self.native);
        _ = systemd.sd_varlink_unref(self.native);
        allocator.destroy(self);
    }

    fn startRequest(self: *Client, lua_state: *c.lua_State, method: []const u8, value_index: c_int, more: bool) !*Request {
        if (self.closed) return error.VarlinkClientClosed;
        if (self.current != null) return error.VarlinkRequestInProgress;
        const allocator = self.host.allocator();
        const method_z = try allocator.dupeZ(u8, method);
        defer allocator.free(method_z);
        const variant = try variantFromLua(lua_state, value_index, allocator);
        defer _ = systemd.sd_json_variant_unref(variant);

        const request = try allocator.create(Request);
        request.* = .{ .client = self };
        errdefer allocator.destroy(request);
        try self.requests.append(allocator, request);
        errdefer _ = self.requests.pop();
        self.current = request;
        errdefer self.current = null;

        if (more) {
            try check(systemd.sd_varlink_observe(self.native, method_z.ptr, variant));
        } else {
            try check(systemd.sd_varlink_invoke(self.native, method_z.ptr, variant));
        }
        return request;
    }

    fn receive(self: *Client, parameters: ?*systemd.sd_json_variant, error_id: [*c]const u8, flags: systemd.sd_varlink_reply_flags_t) !void {
        const request = self.current orelse return error.UnexpectedVarlinkReply;
        const lua_state = self.host.luaState();
        const original_top = c.lua_gettop(lua_state);
        defer c.lua_settop(lua_state, original_top);
        const final = flags & systemd.SD_VARLINK_REPLY_CONTINUES == 0;
        if (final) {
            request.ended = true;
            self.current = null;
        }

        c.lua_createtable(lua_state, 0, 3);
        const response = c.lua_gettop(lua_state);
        try pushParameters(lua_state, self.host.allocator(), parameters);
        c.lua_setfield(lua_state, response, "parameters");
        if (error_id != null) {
            const error_name = std.mem.span(@as([*:0]const u8, @ptrCast(error_id)));
            lua_value.setStringField(lua_state, response, "error", error_name);
        }
        lua_value.setBooleanField(lua_state, response, "continues", !final);
        try request.stream.deliver(self.host.allocator(), lua_state);
        if (final) request.stream.finish(lua_state, .resume_reader);
    }

    fn queueReply(self: *Client, parameters: ?*systemd.sd_json_variant, error_id: [*c]const u8, flags: systemd.sd_varlink_reply_flags_t) !void {
        const allocator = self.host.allocator();
        const reply = try allocator.create(DeferredReply);
        var reply_owns_values = false;
        errdefer if (!reply_owns_values) allocator.destroy(reply);
        const error_name = if (error_id == null)
            null
        else
            try allocator.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(error_id))));
        errdefer if (!reply_owns_values) if (error_name) |name| allocator.free(name);
        reply.* = .{
            .client = self,
            .parameters = if (parameters) |value| systemd.sd_json_variant_ref(value) else null,
            .error_name = error_name,
            .flags = flags,
        };
        reply_owns_values = true;
        errdefer reply.destroy();
        try self.deferred_replies.append(allocator, reply);
        errdefer _ = self.deferred_replies.pop();
        try check(systemd.sd_event_add_defer(self.event, &reply.source, DeferredReply.callback, reply));
        try check(systemd.sd_event_source_set_enabled(reply.source, systemd.SD_EVENT_ONESHOT));
    }

    fn removeDeferredReply(self: *Client, reply: *DeferredReply) void {
        for (self.deferred_replies.items, 0..) |item, index| {
            if (item == reply) {
                _ = self.deferred_replies.swapRemove(index);
                return;
            }
        }
    }
};

const DeferredReply = struct {
    client: *Client,
    parameters: ?*systemd.sd_json_variant,
    error_name: ?[:0]u8,
    flags: systemd.sd_varlink_reply_flags_t,
    source: ?*systemd.sd_event_source = null,

    fn callback(_: ?*systemd.sd_event_source, userdata: ?*anyopaque) callconv(.c) c_int {
        const self: *DeferredReply = @ptrCast(@alignCast(userdata orelse return -1));
        self.client.removeDeferredReply(self);
        const error_name: [*c]const u8 = if (self.error_name) |name| name.ptr else null;
        self.client.receive(self.parameters, error_name, self.flags) catch |err| {
            log.warn("deferred Varlink reply delivery failed: {}", .{err});
            self.destroy();
            return -1;
        };
        self.destroy();
        return 0;
    }

    fn destroy(self: *DeferredReply) void {
        const allocator = self.client.host.allocator();
        if (self.source) |source| _ = systemd.sd_event_source_unref(source);
        if (self.parameters) |parameters| _ = systemd.sd_json_variant_unref(parameters);
        if (self.error_name) |error_name| allocator.free(error_name);
        allocator.destroy(self);
    }
};

const Request = struct {
    client: *Client,
    stream: lua_coro.Stream = .{},
    handle_ref: c_int = -1,
    ended: bool = false,

    fn finish(self: *Request, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        if (self.ended) return;
        self.ended = true;
        if (self.client.current == self) self.client.current = null;
        self.stream.finish(lua_state, mode);
    }

    pub fn cancel(self: *Request, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        if (!self.ended) self.client.close(lua_state, mode);
    }

    fn destroy(self: *Request, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.finish(lua_state, .silent);
        self.stream.cancel(allocator, lua_state, .silent);
        lua_handle.invalidate(lua_state, self.handle_ref);
        allocator.destroy(self);
    }
};

const PendingCall = struct {
    server: *Server,
    link: *systemd.sd_varlink,
    handle_ref: c_int = -1,
    completed: bool = false,

    fn finish(self: *PendingCall, lua_state: *c.lua_State) void {
        if (self.completed) return;
        self.completed = true;
        _ = self.server.removePending(self);
        self.destroyDetached(lua_state);
    }

    fn destroyDetached(self: *PendingCall, lua_state: *c.lua_State) void {
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
        _ = systemd.sd_varlink_unref(self.link);
        self.server.host.allocator().destroy(self);
    }

    fn destroy(self: *PendingCall, lua_state: *c.lua_State) void {
        self.finish(lua_state);
    }
};

pub const Server = struct {
    host: Host,
    native: *systemd.sd_varlink_server,
    methods_ref: c_int,
    handle_ref: c_int = -1,
    pending: std.ArrayList(*PendingCall) = .empty,
    closed: bool = false,

    pub fn create(host: Host, options: ServeOptions) !*Server {
        const allocator = host.allocator();
        errdefer c.luaL_unref(host.luaState(), c.LUA_REGISTRYINDEX, options.methods_ref);
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        var native: ?*systemd.sd_varlink_server = null;
        const flags: systemd.sd_varlink_server_flags_t = systemd.SD_VARLINK_SERVER_INHERIT_USERDATA;
        try checkOperation("server new", systemd.sd_varlink_server_new(&native, flags));
        errdefer _ = systemd.sd_varlink_server_unref(native.?);
        self.* = .{
            .host = host,
            .native = native.?,
            .methods_ref = options.methods_ref,
        };
        _ = systemd.sd_varlink_server_set_userdata(self.native, self);

        try self.bindMethods();
        const bridge = try host.systemdEvent();
        try checkOperation("server attach event", systemd.sd_varlink_server_attach_event(self.native, bridge.sdEvent(), 0));
        errdefer _ = systemd.sd_varlink_server_detach_event(self.native);

        if (options.address) |address| {
            const address_z = try allocator.dupeZ(u8, address);
            defer allocator.free(address_z);
            log.debug("listening at Varlink address {s}", .{address});
            try checkOperation("server listen address", systemd.sd_varlink_server_listen_address(self.native, address_z.ptr, 0o600));
        } else {
            const listened = try checkResult(systemd.sd_varlink_server_listen_auto(self.native));
            if (listened == 0) return error.NoVarlinkActivationSocket;
        }
        return self;
    }

    fn bindMethods(self: *Server) !void {
        const lua_state = self.host.luaState();
        const original_top = c.lua_gettop(lua_state);
        defer c.lua_settop(lua_state, original_top);
        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, self.methods_ref);
        const methods = c.lua_gettop(lua_state);
        c.lua_pushnil(lua_state);
        while (c.lua_next(lua_state, methods) != 0) {
            defer c.lua_settop(lua_state, -2);
            if (c.lua_type(lua_state, -2) != c.LUA_TSTRING or c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.InvalidVarlinkMethods;
            const method = try lua_value.stringFromStack(lua_state, -2);
            const method_z = try self.host.allocator().dupeZ(u8, method);
            defer self.host.allocator().free(method_z);
            try checkOperation("server bind method", systemd.sd_varlink_server_bind_method(self.native, method_z.ptr, methodCallback));
        }
    }

    pub fn cancel(self: *Server, lua_state: *c.lua_State, _: lua_coro.CancelMode) void {
        self.close(lua_state);
    }

    pub fn close(self: *Server, lua_state: *c.lua_State) void {
        if (self.closed) return;
        self.closed = true;
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
        while (self.pending.pop()) |pending| pending.destroy(lua_state);
        _ = systemd.sd_varlink_server_shutdown(self.native);
    }

    pub fn destroy(self: *Server, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.close(lua_state);
        _ = systemd.sd_varlink_server_detach_event(self.native);
        _ = systemd.sd_varlink_server_unref(self.native);
        if (self.methods_ref >= 0) c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.methods_ref);
        self.methods_ref = -1;
        self.pending.deinit(allocator);
        allocator.destroy(self);
    }

    fn removePending(self: *Server, pending: *PendingCall) bool {
        for (self.pending.items, 0..) |item, index| {
            if (item == pending) {
                _ = self.pending.swapRemove(index);
                return true;
            }
        }
        return false;
    }

    fn hasPending(self: *const Server, pending: *const PendingCall) bool {
        for (self.pending.items) |item| if (item == pending) return true;
        return false;
    }

    fn dispatch(self: *Server, link: *systemd.sd_varlink, parameters: ?*systemd.sd_json_variant, flags: systemd.sd_varlink_method_flags_t) !void {
        if (self.closed) return error.VarlinkServerClosed;
        var method_z: [*c]const u8 = null;
        try check(systemd.sd_varlink_get_current_method(link, &method_z));
        if (method_z == null) return error.MissingVarlinkMethod;
        const method = std.mem.span(@as([*:0]const u8, @ptrCast(method_z)));

        const allocator = self.host.allocator();
        const pending = try allocator.create(PendingCall);
        var pending_owned = false;
        pending.* = .{
            .server = self,
            .link = systemd.sd_varlink_ref(link).?,
        };
        errdefer {
            if (pending_owned) {
                if (self.removePending(pending)) pending.destroyDetached(self.host.luaState());
            } else {
                _ = systemd.sd_varlink_unref(pending.link);
                allocator.destroy(pending);
            }
        }
        try self.pending.append(allocator, pending);
        pending_owned = true;

        const lua_state = self.host.luaState();
        const original_top = c.lua_gettop(lua_state);
        defer c.lua_settop(lua_state, original_top);

        c.lua_getfield(lua_state, c.LUA_REGISTRYINDEX, dispatch_registry_key);
        pending.handle_ref = lua_handle.create(lua_state, pending_call_type, &pending_call_methods, pending);
        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, self.methods_ref);
        c.lua_pushlstring(lua_state, method.ptr, method.len);
        c.lua_rawget(lua_state, -2);
        c.lua_remove(lua_state, -2);
        if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) return error.UnknownVarlinkMethod;
        c.lua_pushlstring(lua_state, method.ptr, method.len);
        const more = flags & systemd.SD_VARLINK_METHOD_MORE != 0;
        c.lua_pushboolean(lua_state, @intFromBool(more));
        try pushParameters(lua_state, allocator, parameters);
        if (c.lua_pcall(lua_state, 5, 0, 0) != 0) {
            const message = lua_value.stringFromStack(lua_state, -1) catch "Varlink dispatch failed";
            if (self.hasPending(pending)) self.sendError(pending, "org.keywork.LuaError", message) catch {};
            return error.VarlinkDispatchFailed;
        }
    }

    fn sendValue(self: *Server, pending: *PendingCall, lua_state: *c.lua_State, value_index: c_int, kind: enum { reply, notify }) !void {
        const variant = try variantFromLua(lua_state, value_index, self.host.allocator());
        defer _ = systemd.sd_json_variant_unref(variant);
        switch (kind) {
            .reply => try check(systemd.sd_varlink_reply(pending.link, variant)),
            .notify => try check(systemd.sd_varlink_notify(pending.link, variant)),
        }
    }

    fn sendErrorValue(self: *Server, pending: *PendingCall, lua_state: *c.lua_State, name: []const u8, value_index: c_int) !void {
        const allocator = self.host.allocator();
        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);
        const variant = try variantFromLua(lua_state, value_index, allocator);
        defer _ = systemd.sd_json_variant_unref(variant);
        // sd_varlink_error() returns the error translated to a negative
        // errno even after successfully queueing it. Application-defined
        // error names normally produce -EBADR, so this is not a send status.
        _ = systemd.sd_varlink_error(pending.link, name_z.ptr, variant);
    }

    fn sendError(self: *Server, pending: *PendingCall, name: []const u8, message: []const u8) !void {
        const lua_state = self.host.luaState();
        c.lua_createtable(lua_state, 0, 1);
        defer c.lua_settop(lua_state, -2);
        c.lua_pushlstring(lua_state, message.ptr, message.len);
        c.lua_setfield(lua_state, -2, "message");
        try self.sendErrorValue(pending, lua_state, name, c.lua_gettop(lua_state));
    }
};

pub fn pushModule(lua_state: *c.lua_State, host: *Host) void {
    c.lua_createtable(lua_state, 0, 2);
    const module = c.lua_gettop(lua_state);
    c.lua_pushlightuserdata(lua_state, host);
    lua_value.setClosureField(lua_state, module, "serve", luaServe, 1);
    c.lua_pushlightuserdata(lua_state, host);
    lua_value.setClosureField(lua_state, module, "connect", luaConnect, 1);

    if (c.luaL_loadbuffer(lua_state, embedded_source.ptr, embedded_source.len, "@keywork/varlink.lua") != 0) {
        _ = c.lua_error(lua_state);
        unreachable;
    }
    c.lua_pushvalue(lua_state, module);
    lua_handle.pushMethodsTable(lua_state, client_type, &client_methods);
    c.lua_call(lua_state, 2, 1);
    c.lua_setfield(lua_state, c.LUA_REGISTRYINDEX, dispatch_registry_key);
}

fn hostFromLua(lua_state: *c.lua_State) Host {
    return lua_value.upvaluePointer(*Host, lua_state, 1).*;
}

fn luaServe(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.luaL_checktype(lua_state, 1, c.LUA_TTABLE);
    const host = hostFromLua(lua_state);
    lua_task.raiseIfCanceled(lua_state);

    c.lua_getfield(lua_state, 1, "methods");
    c.luaL_checktype(lua_state, -1, c.LUA_TTABLE);
    const methods_ref = c.luaL_ref(lua_state, c.LUA_REGISTRYINDEX);

    c.lua_getfield(lua_state, 1, "address");
    const address: ?[]const u8 = if (c.lua_isnil(lua_state, -1)) null else lua_value.checkString(lua_state, -1);

    const server = host.addServer(.{ .methods_ref = methods_ref, .address = address }) catch |err| {
        c.lua_settop(lua_state, -2);
        log.warn("varlink serve failed: {}", .{err});
        return lua_value.pushNilError(lua_state, err);
    };
    c.lua_settop(lua_state, -2);
    lua_task.adoptResource(Server, lua_state, server);
    server.handle_ref = lua_handle.create(lua_state, server_type, &server_methods, server);
    return 1;
}

fn luaConnect(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const host = hostFromLua(lua_state);
    lua_task.raiseIfCanceled(lua_state);
    const address = lua_value.checkString(lua_state, 1);
    const client = host.addClient(address) catch |err| {
        log.warn("varlink connect failed: {}", .{err});
        return lua_value.pushNilError(lua_state, err);
    };
    lua_task.adoptResource(Client, lua_state, client);
    client.handle_ref = lua_handle.create(lua_state, client_type, &client_methods, client);
    return 1;
}

fn methodCallback(link_optional: ?*systemd.sd_varlink, parameters: ?*systemd.sd_json_variant, flags: systemd.sd_varlink_method_flags_t, userdata: ?*anyopaque) callconv(.c) c_int {
    const server: *Server = @ptrCast(@alignCast(userdata orelse return -1));
    server.dispatch(link_optional orelse return -1, parameters, flags) catch |err| {
        log.warn("varlink method dispatch failed: {}", .{err});
        return -1;
    };
    return 1;
}

fn replyCallback(_: ?*systemd.sd_varlink, parameters: ?*systemd.sd_json_variant, error_id: [*c]const u8, flags: systemd.sd_varlink_reply_flags_t, userdata: ?*anyopaque) callconv(.c) c_int {
    const client: *Client = @ptrCast(@alignCast(userdata orelse return -1));
    client.queueReply(parameters, error_id, flags) catch |err| {
        log.warn("varlink reply queueing failed: {}", .{err});
        return -1;
    };
    return 0;
}

fn pushParameters(lua_state: *c.lua_State, allocator: std.mem.Allocator, parameters: ?*systemd.sd_json_variant) !void {
    const value = parameters orelse {
        c.lua_createtable(lua_state, 0, 0);
        return;
    };
    var text_ptr: [*c]u8 = null;
    try check(systemd.sd_json_variant_format(value, 0, &text_ptr));
    defer std.c.free(text_ptr);
    if (text_ptr == null) return error.VarlinkJsonFormatFailed;
    const text = std.mem.span(@as([*:0]const u8, @ptrCast(text_ptr)));
    try lua_json.pushDecoded(lua_state, allocator, text);
}

fn variantFromLua(lua_state: *c.lua_State, index: c_int, allocator: std.mem.Allocator) !*systemd.sd_json_variant {
    const text = try lua_json.encodeAlloc(lua_state, index, allocator);
    defer allocator.free(text);
    const text_z = try allocator.dupeZ(u8, text);
    defer allocator.free(text_z);
    var variant: ?*systemd.sd_json_variant = null;
    try check(systemd.sd_json_parse(text_z.ptr, 0, &variant, null, null));
    return variant.?;
}

const server_type: [*:0]const u8 = "keywork.varlink_server";
const server_methods = [_]lua_handle.Method{
    .{ .name = "close", .func = luaServerClose },
    .{ .name = "closed", .func = luaServerClosed },
};

const client_type: [*:0]const u8 = "keywork.varlink_client";
const client_methods = [_]lua_handle.Method{
    .{ .name = "request", .func = luaClientRequest },
    .{ .name = "close", .func = luaClientClose },
    .{ .name = "closed", .func = luaClientClosed },
};

const request_type: [*:0]const u8 = "keywork.varlink_request";
const request_methods = [_]lua_handle.Method{
    .{ .name = "next", .func = luaRequestNext },
    .{ .name = "replies", .func = luaRequestReplies },
    .{ .name = "cancel", .func = luaRequestCancel },
};

const pending_call_type: [*:0]const u8 = "keywork.varlink_call";
const pending_call_methods = [_]lua_handle.Method{
    .{ .name = "reply", .func = luaPendingReply },
    .{ .name = "notify", .func = luaPendingNotify },
    .{ .name = "error", .func = luaPendingError },
};

fn luaServerClose(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const server = lua_handle.resource(Server, lua_state, 1, server_type) orelse return 0;
    server.close(lua_state);
    return 0;
}

fn luaServerClosed(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const server = lua_handle.resource(Server, lua_state, 1, server_type) orelse {
        c.lua_pushboolean(lua_state, 1);
        return 1;
    };
    c.lua_pushboolean(lua_state, @intFromBool(server.closed));
    return 1;
}

fn luaClientRequest(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const client = lua_handle.resource(Client, lua_state, 1, client_type) orelse return lua_value.pushNilError(lua_state, error.VarlinkClientClosed);
    lua_task.raiseIfCanceled(lua_state);
    const method = lua_value.checkString(lua_state, 2);
    const more = c.lua_toboolean(lua_state, 4) != 0;
    const missing_parameters = c.lua_gettop(lua_state) < 3 or c.lua_isnil(lua_state, 3);
    if (missing_parameters) c.lua_createtable(lua_state, 0, 0);
    const value_index: c_int = if (missing_parameters) c.lua_gettop(lua_state) else 3;
    const request = client.startRequest(lua_state, method, value_index, more) catch |err| {
        log.warn("varlink request failed: {}", .{err});
        return lua_value.pushNilError(lua_state, err);
    };
    lua_task.adoptResource(Request, lua_state, request);
    request.handle_ref = lua_handle.create(lua_state, request_type, &request_methods, request);
    return 1;
}

fn luaClientClose(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const client = lua_handle.resource(Client, lua_state, 1, client_type) orelse return 0;
    client.close(lua_state, .resume_reader);
    return 0;
}

fn luaClientClosed(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const client = lua_handle.resource(Client, lua_state, 1, client_type) orelse {
        c.lua_pushboolean(lua_state, 1);
        return 1;
    };
    c.lua_pushboolean(lua_state, @intFromBool(client.closed));
    return 1;
}

fn luaRequestNext(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const request = lua_handle.resource(Request, lua_state, 1, request_type) orelse return 0;
    return request.stream.awaitNext(lua_state, request.ended);
}

fn luaRequestReplies(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    _ = c.luaL_checkudata(lua_state, 1, request_type);
    return lua_coro.pushIterator(lua_state, luaRequestNext);
}

fn luaRequestCancel(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const request = lua_handle.resource(Request, lua_state, 1, request_type) orelse return 0;
    request.cancel(lua_state, .resume_reader);
    return 0;
}

fn luaPendingReply(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const pending = lua_handle.resource(PendingCall, lua_state, 1, pending_call_type) orelse return 0;
    if (c.lua_gettop(lua_state) < 2 or c.lua_isnil(lua_state, 2)) c.lua_createtable(lua_state, 0, 0);
    const value_index = c.lua_gettop(lua_state);
    pending.server.sendValue(pending, lua_state, value_index, .reply) catch |err| {
        log.warn("varlink reply failed: {}", .{err});
        pending.server.sendError(pending, "org.keywork.LuaError", @errorName(err)) catch {
            _ = systemd.sd_varlink_error_errno(pending.link, @intFromEnum(std.posix.E.INVAL));
        };
    };
    pending.finish(lua_state);
    return 0;
}

fn luaPendingNotify(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const pending = lua_handle.resource(PendingCall, lua_state, 1, pending_call_type) orelse return 0;
    if (c.lua_gettop(lua_state) < 2 or c.lua_isnil(lua_state, 2)) c.lua_createtable(lua_state, 0, 0);
    const value_index = c.lua_gettop(lua_state);
    pending.server.sendValue(pending, lua_state, value_index, .notify) catch |err| {
        log.warn("varlink notify failed: {}", .{err});
        return lua_value.pushNilError(lua_state, err);
    };
    c.lua_pushboolean(lua_state, 1);
    return 1;
}

fn luaPendingError(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const pending = lua_handle.resource(PendingCall, lua_state, 1, pending_call_type) orelse return 0;
    const name = lua_value.checkString(lua_state, 2);
    if (c.lua_gettop(lua_state) < 3 or c.lua_isnil(lua_state, 3)) c.lua_createtable(lua_state, 0, 0);
    const value_index = c.lua_gettop(lua_state);
    pending.server.sendErrorValue(pending, lua_state, name, value_index) catch |err| {
        log.warn("varlink error reply failed: {}", .{err});
        pending.server.sendError(pending, "org.keywork.LuaError", @errorName(err)) catch {
            _ = systemd.sd_varlink_error_errno(pending.link, @intFromEnum(std.posix.E.INVAL));
        };
    };
    pending.finish(lua_state);
    return 0;
}

fn check(result: c_int) !void {
    if (result < 0) {
        log.warn("sd-varlink operation failed with errno {d}", .{-result});
        return error.SystemdVarlinkFailed;
    }
}

fn checkOperation(comptime operation: []const u8, result: c_int) !void {
    if (result < 0) {
        log.warn("sd-varlink {s} failed with errno {d}", .{ operation, -result });
        return error.SystemdVarlinkFailed;
    }
}

fn checkResult(result: c_int) !c_int {
    if (result < 0) {
        log.warn("sd-varlink operation failed with errno {d}", .{-result});
        return error.SystemdVarlinkFailed;
    }
    return result;
}
