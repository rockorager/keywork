//! Generic asynchronous client byte streams for keywork.net.
//!
//! libcurl's connect-only mode supplies DNS, TCP, TLS, proxy negotiation,
//! certificate verification, and Happy Eyeballs. Once established, a
//! Connection exposes protocol-neutral chunks and backpressured writes; HTTP
//! and other protocol modules can instead attach ordinary transfers to the
//! same shared curl runtime.

const std = @import("std");
const event_loop = @import("../linux/event_loop.zig");
const lua_coro = @import("coro.zig");
const lua_curl = @import("curl.zig");
const lua_handle = @import("handle.zig");
const lua_sink = @import("sink.zig");
const lua_socket = @import("socket.zig");
const lua_task = @import("task.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");
const curl_c = @import("curl_c");

const linux = std.os.linux;
const log = std.log.scoped(.keywork_net);

pub const ConnectOptions = struct {
    host: []const u8,
    port: u16,
    tls: bool,
    connect_timeout_ms: u64,
    proxy: ?[]const u8,
};

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allocator: *const fn (*anyopaque) std.mem.Allocator,
        luaState: *const fn (*anyopaque) *c.lua_State,
        eventLoop: *const fn (*anyopaque) ?*event_loop.EventLoop,
        addConnection: *const fn (*anyopaque, ConnectOptions, c_int) anyerror!*Connection,
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

    fn addConnection(self: Host, options: ConnectOptions, waiter_ref: c_int) !*Connection {
        return self.vtable.addConnection(self.ptr, options, waiter_ref);
    }
};

pub const Connection = struct {
    host: Host,
    runtime: *lua_curl.Runtime,
    transfer: lua_curl.Transfer,
    fd: curl_c.curl_socket_t = curl_c.CURL_SOCKET_BAD,
    stream: lua_coro.Stream = .{},
    sink: lua_sink.Sink = .{},
    connect_ref: c_int,
    handle_ref: c_int = -1,
    source_handle: ?event_loop.EventLoop.SourceHandle = null,
    connected: bool = false,
    cleaned: bool = false,
    canceled: bool = false,

    pub fn init(host: Host, runtime: *lua_curl.Runtime, options: ConnectOptions, connect_ref: c_int) !Connection {
        const easy = curl_c.curl_easy_init() orelse return error.CurlInitFailed;
        errdefer curl_c.curl_easy_cleanup(easy);

        const allocator = host.allocator();
        const url = try connectUrl(allocator, options);
        defer allocator.free(url);

        try setOption(easy, curl_c.CURLOPT_URL, url.ptr);
        try setOption(easy, curl_c.CURLOPT_CONNECT_ONLY, @as(c_long, 1));
        try setOption(easy, curl_c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        try setOption(easy, curl_c.CURLOPT_TCP_KEEPALIVE, @as(c_long, 1));
        // HTTPS is used only to ask curl for TLS. Do not advertise HTTP ALPN
        // protocols on this otherwise protocol-neutral byte stream.
        try setOption(easy, curl_c.CURLOPT_SSL_ENABLE_ALPN, @as(c_long, 0));
        try setOption(easy, curl_c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, @intCast(options.connect_timeout_ms)));

        // Raw streams have no universal ambient proxy convention. Disable
        // environment proxies unless the caller explicitly asks for one;
        // an explicit HTTP proxy is tunneled so no HTTP bytes reach the peer.
        if (options.proxy) |proxy| {
            const proxy_z = try allocator.dupeZ(u8, proxy);
            defer allocator.free(proxy_z);
            try setOption(easy, curl_c.CURLOPT_PROXY, proxy_z.ptr);
            try setOption(easy, curl_c.CURLOPT_HTTPPROXYTUNNEL, @as(c_long, 1));
        } else {
            try setOption(easy, curl_c.CURLOPT_PROXY, "");
        }

        return .{
            .host = host,
            .runtime = runtime,
            .transfer = .{ .easy = easy, .complete_fn = transferComplete },
            .connect_ref = connect_ref,
        };
    }

    pub fn register(self: *Connection) !void {
        if (!self.connected or self.cleaned or self.source_handle != null) return;
        const loop = self.host.eventLoop() orelse return;
        self.source_handle = try loop.addFd(.{
            .fd = self.fd,
            .events = self.wantedEvents(),
            .ctx = self,
            .callback = connectionReady,
        });
    }

    pub fn unregister(self: *Connection, loop: *event_loop.EventLoop) void {
        if (self.source_handle) |handle| loop.removeSource(handle);
        self.source_handle = null;
    }

    pub fn live(self: *const Connection) bool {
        return !self.canceled and !self.cleaned;
    }

    pub fn cancel(self: *Connection, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        if (self.canceled) return;
        self.canceled = true;
        self.closeTransport();
        self.sink.fail(lua_state, mode, "closed");
        self.finishConnect(lua_state, mode, "canceled");
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
        self.stream.cancel(self.host.allocator(), lua_state, mode);
    }

    pub fn destroy(self: *Connection, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cancel(lua_state, .silent);
        allocator.destroy(self);
    }

    /// Tears down an initialized connection when its host could not adopt it.
    /// The caller still owns `connect_ref` on this path.
    pub fn discardSetup(self: *Connection, allocator: std.mem.Allocator) void {
        self.closeTransport();
        allocator.destroy(self);
    }

    fn wantedEvents(self: *const Connection) u32 {
        var events: u32 = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR;
        if (self.sink.hasPending()) events |= linux.EPOLL.OUT;
        return events;
    }

    fn updateInterests(self: *Connection) void {
        const loop = self.host.eventLoop() orelse return;
        if (self.source_handle) |handle| loop.modifySource(handle, self.wantedEvents());
    }

    fn closeTransport(self: *Connection) void {
        if (self.cleaned) return;
        if (self.host.eventLoop()) |loop| self.unregister(loop);
        self.runtime.remove(&self.transfer);
        curl_c.curl_easy_cleanup(self.transfer.easy);
        self.cleaned = true;
        self.fd = curl_c.CURL_SOCKET_BAD;
        self.sink.clear(self.host.allocator());
    }

    fn shutdown(self: *Connection, mode: lua_coro.CancelMode) void {
        if (self.cleaned) return;
        const lua_state = self.host.luaState();
        self.closeTransport();
        self.sink.fail(lua_state, mode, "closed");
        self.stream.finish(lua_state, mode);
    }

    fn finishConnect(self: *Connection, lua_state: *c.lua_State, mode: lua_coro.CancelMode, message: []const u8) void {
        if (self.connect_ref < 0) return;
        switch (mode) {
            .resume_reader => {
                c.lua_pushnil(lua_state);
                c.lua_pushlstring(lua_state, message.ptr, message.len);
                lua_coro.resumeReaderWith(lua_state, &self.connect_ref, 2);
            },
            .silent => {
                c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.connect_ref);
                self.connect_ref = -1;
            },
        }
    }

    fn connectFailed(self: *Connection, message: []const u8) void {
        const lua_state = self.host.luaState();
        self.closeTransport();
        self.finishConnect(lua_state, .resume_reader, message);
    }

    fn connectedReady(self: *Connection, fd: curl_c.curl_socket_t) void {
        self.runtime.releaseSource(fd);
        self.fd = fd;
        self.connected = true;
        self.register() catch |err| {
            self.connectFailed(@errorName(err));
            return;
        };
        self.drainReadable();
        if (self.cleaned) {
            self.finishConnect(self.host.luaState(), .resume_reader, "closed during connect");
            return;
        }

        const lua_state = self.host.luaState();
        self.handle_ref = lua_handle.create(lua_state, connection_type, &connection_methods, self);
        lua_coro.resumeReaderWith(lua_state, &self.connect_ref, 1);
    }

    fn drainReadable(self: *Connection) void {
        var buffer: [16 * 1024]u8 = undefined;
        while (!self.cleaned) {
            var received: usize = 0;
            const result = curl_c.curl_easy_recv(self.transfer.easy, &buffer, buffer.len, &received);
            if (result == curl_c.CURLE_AGAIN) return;
            if (result != curl_c.CURLE_OK) {
                self.shutdown(.resume_reader);
                return;
            }
            if (received == 0) {
                self.shutdown(.resume_reader);
                return;
            }
            const lua_state = self.host.luaState();
            c.lua_pushlstring(lua_state, &buffer, received);
            self.stream.deliver(self.host.allocator(), lua_state) catch |err| {
                log.warn("network stream delivery failed: {}", .{err});
            };
        }
    }

    fn writeNow(self: *Connection, data: []const u8) !usize {
        var offset: usize = 0;
        while (offset < data.len) {
            var sent: usize = 0;
            const result = curl_c.curl_easy_send(self.transfer.easy, data.ptr + offset, data.len - offset, &sent);
            if (result == curl_c.CURLE_AGAIN) return offset;
            if (result != curl_c.CURLE_OK) return error.SendFailed;
            if (sent == 0) return offset;
            offset += sent;
        }
        return offset;
    }

    fn flush(self: *Connection) !bool {
        const written = try self.writeNow(self.sink.buffer.items);
        self.sink.buffer.replaceRangeAssumeCapacity(0, written, &.{});
        return self.sink.buffer.items.len == 0;
    }
};

fn transferComplete(transfer: *lua_curl.Transfer, result: curl_c.CURLcode) void {
    const connection: *Connection = @alignCast(@fieldParentPtr("transfer", transfer));
    if (connection.canceled or connection.cleaned) return;
    if (result != curl_c.CURLE_OK) {
        connection.connectFailed(std.mem.span(curl_c.curl_easy_strerror(result)));
        return;
    }

    var fd: curl_c.curl_socket_t = curl_c.CURL_SOCKET_BAD;
    const info_result = curl_c.curl_easy_getinfo(
        transfer.easy,
        @as(curl_c.CURLINFO, @intCast(curl_c.CURLINFO_ACTIVESOCKET)),
        &fd,
    );
    if (info_result != curl_c.CURLE_OK or fd == curl_c.CURL_SOCKET_BAD) {
        connection.connectFailed("connection has no active socket");
        return;
    }
    connection.connectedReady(fd);
}

fn connectionReady(ctx: *anyopaque, _: *event_loop.EventLoop, events: u32) !void {
    const connection: *Connection = @ptrCast(@alignCast(ctx));
    if (connection.cleaned or connection.canceled) return;
    const lua_state = connection.host.luaState();

    if (events & linux.EPOLL.OUT != 0 and connection.sink.hasPending()) {
        const flushed = connection.flush() catch {
            connection.shutdown(.resume_reader);
            return;
        };
        if (flushed) {
            connection.updateInterests();
            connection.sink.resolve(lua_state);
            if (connection.cleaned or connection.canceled) return;
        }
    }
    if (events & (linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR) != 0) {
        connection.drainReadable();
    }
    // Error and hangup are level-triggered. If curl consumed only TLS control
    // bytes and still reported AGAIN, close rather than spinning forever.
    if (!connection.cleaned and events & (linux.EPOLL.HUP | linux.EPOLL.ERR) != 0) {
        connection.shutdown(.resume_reader);
    }
}

pub fn pushModule(lua_state: *c.lua_State, host: *Host, socket_host: *lua_socket.Host) void {
    c.lua_createtable(lua_state, 0, 1);
    c.lua_pushlightuserdata(lua_state, host);
    c.lua_pushlightuserdata(lua_state, socket_host);
    lua_value.setClosureField(lua_state, -3, "connect", luaConnect, 2);
}

fn hostFromLua(lua_state: *c.lua_State) Host {
    return lua_value.upvaluePointer(*Host, lua_state, 1).*;
}

fn socketHostFromLua(lua_state: *c.lua_State) lua_socket.Host {
    return lua_value.upvaluePointer(*lua_socket.Host, lua_state, 2).*;
}

const connection_type: [*:0]const u8 = "keywork.net.connection";
const connection_methods = [_]lua_handle.Method{
    .{ .name = "next", .func = luaConnectionNext },
    .{ .name = "chunks", .func = luaConnectionChunks },
    .{ .name = "write", .func = luaConnectionWrite },
    .{ .name = "close", .func = luaConnectionClose },
    .{ .name = "cancel", .func = luaConnectionClose },
    .{ .name = "closed", .func = luaConnectionClosed },
};

fn luaConnect(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const host = hostFromLua(lua_state);
    lua_task.raiseIfCanceled(lua_state);
    const uri_text = lua_value.checkString(lua_state, 1);
    const uri = std.Uri.parse(uri_text) catch return c.luaL_error(lua_state, "net.connect requires a valid URI");
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) {
        return c.luaL_error(lua_state, "network URIs do not support userinfo, query strings, or fragments");
    }

    if (std.ascii.eqlIgnoreCase(uri.scheme, "unix")) {
        if (uri.host != null or uri.port != null or uri.path.isEmpty()) {
            return c.luaL_error(lua_state, "unix URI must contain a socket path, for example unix:///run/service.sock");
        }
        if (c.lua_gettop(lua_state) >= 2 and !c.lua_isnil(lua_state, 2)) {
            return c.luaL_error(lua_state, "unix connections do not accept connection options");
        }
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = uri.path.toRaw(&path_buffer) catch return c.luaL_error(lua_state, "unix socket path is too long");
        return lua_socket.connectPath(lua_state, socketHostFromLua(lua_state), path);
    }

    const tls = if (std.ascii.eqlIgnoreCase(uri.scheme, "tcp"))
        false
    else if (std.ascii.eqlIgnoreCase(uri.scheme, "tls"))
        true
    else
        return c.luaL_error(lua_state, "unsupported network URI scheme (expected tcp, tls, or unix)");
    if (lua_coro.onMainThread(lua_state)) return c.luaL_error(lua_state, "TCP and TLS connections must be opened from a coroutine (wrap the caller in loop.spawn)");
    if (uri.host == null or uri.port == null or uri.port.? == 0 or !uri.path.isEmpty()) {
        return c.luaL_error(lua_state, "tcp and tls URIs must contain only a host and port");
    }

    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const name = (uri.getHost(&host_buffer) catch return c.luaL_error(lua_state, "network URI requires a host")).bytes;
    if (!validNetworkHost(name)) return c.luaL_error(lua_state, "network URI contains an invalid host");

    var timeout_seconds: f64 = 30.0;
    var proxy: ?[]const u8 = null;
    if (c.lua_gettop(lua_state) >= 2 and !c.lua_isnil(lua_state, 2)) {
        c.luaL_checktype(lua_state, 2, c.LUA_TTABLE);
        c.lua_getfield(lua_state, 2, "connect_timeout");
        if (!c.lua_isnil(lua_state, -1)) timeout_seconds = c.luaL_checknumber(lua_state, -1);
        lua_value.pop(lua_state, 1);
        c.lua_getfield(lua_state, 2, "proxy");
        if (!c.lua_isnil(lua_state, -1)) proxy = lua_value.checkString(lua_state, -1);
        lua_value.pop(lua_state, 1);
    }
    if (!std.math.isFinite(timeout_seconds) or timeout_seconds <= 0 or timeout_seconds > @as(f64, @floatFromInt(std.math.maxInt(c_long))) / 1000.0) {
        return c.luaL_error(lua_state, "net.connect connect_timeout must be a positive number of seconds");
    }

    const options: ConnectOptions = .{
        .host = name,
        .port = uri.port.?,
        .tls = tls,
        .connect_timeout_ms = @intFromFloat(@ceil(timeout_seconds * 1000.0)),
        .proxy = proxy,
    };

    const waiter_ref = lua_coro.refCurrentThread(lua_state);
    const connection = host.addConnection(options, waiter_ref) catch |err| {
        c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, waiter_ref);
        log.warn("network connection setup failed: {}", .{err});
        return c.luaL_error(lua_state, "network connection setup failed");
    };
    lua_task.adoptResource(Connection, lua_state, connection);
    return c.lua_yield(lua_state, 0);
}

fn luaConnectionNext(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const connection = lua_handle.resource(Connection, lua_state, 1, connection_type) orelse return 0;
    return connection.stream.awaitNext(lua_state, connection.cleaned or connection.canceled);
}

fn luaConnectionChunks(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    _ = c.luaL_checkudata(lua_state, 1, connection_type);
    return lua_coro.pushIterator(lua_state, luaConnectionNext);
}

fn luaConnectionWrite(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const connection_or_dead = lua_handle.resource(Connection, lua_state, 1, connection_type);
    const data = lua_value.checkString(lua_state, 2);
    const connection = connection_or_dead orelse return lua_value.pushNilMessage(lua_state, "closed");
    if (connection.cleaned or connection.canceled) return lua_value.pushNilMessage(lua_state, "closed");
    if (connection.sink.hasWaiter()) return c.luaL_error(lua_state, "connection already has a waiting writer");

    const written = connection.writeNow(data) catch {
        connection.shutdown(.resume_reader);
        return lua_value.pushNilMessage(lua_state, "send failed");
    };
    if (written == data.len) {
        c.lua_pushboolean(lua_state, 1);
        return 1;
    }
    if (lua_coro.onMainThread(lua_state)) return c.luaL_error(lua_state, "connection write would block; call write from a coroutine (wrap the caller in loop.spawn)");
    const yielded = connection.sink.park(connection.host.allocator(), lua_state, data[written..]) catch return c.luaL_error(lua_state, "connection write failed");
    connection.updateInterests();
    return yielded;
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
    c.lua_pushboolean(lua_state, @intFromBool(connection.cleaned or connection.canceled));
    return 1;
}

fn connectUrl(allocator: std.mem.Allocator, options: ConnectOptions) ![:0]u8 {
    const scheme = if (options.tls) "https" else "http";
    const bracketed = options.host.len >= 2 and options.host[0] == '[' and options.host[options.host.len - 1] == ']';
    if (!bracketed and std.mem.indexOfScalar(u8, options.host, ':') != null) {
        return std.fmt.allocPrintSentinel(allocator, "{s}://[{s}]:{d}/", .{ scheme, options.host, options.port }, 0);
    }
    return std.fmt.allocPrintSentinel(allocator, "{s}://{s}:{d}/", .{ scheme, options.host, options.port }, 0);
}

fn validNetworkHost(host: []const u8) bool {
    if (host.len == 0) return false;
    for (host) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '/' or byte == '\\' or byte == '@' or byte == '?' or byte == '#') return false;
    }
    return true;
}

fn setOption(easy: *curl_c.CURL, option: c_int, value: anytype) !void {
    try lua_curl.curlCode(curl_c.curl_easy_setopt(
        easy,
        @as(curl_c.CURLoption, @intCast(option)),
        value,
    ));
}
