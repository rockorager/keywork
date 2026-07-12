//! Lua D-Bus integration for keywork.dbus.

const std = @import("std");
const event_loop = @import("../linux/event_loop.zig");
const lua_coro = @import("coro.zig");
const lua_handle = @import("handle.zig");
const lua_task = @import("task.zig");
const lua_value = @import("value.zig");
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

    // The property/proxy/observe sugar must suspend through bus:call, so it
    // is implemented as Lua closures layered on the bus methods table rather
    // than as C functions, which cannot yield across lua_call. The chunk
    // returns the exported-method dispatcher, which must be pure Lua for the
    // same reason: handlers yield inside the task it spawns.
    if (c.luaL_loadbuffer(lua_state, embedded_dbus_source.ptr, embedded_dbus_source.len, "@keywork/dbus.lua") != 0) {
        _ = c.lua_error(lua_state);
        unreachable;
    }
    lua_handle.pushMethodsTable(lua_state, bus_type, &bus_methods);
    c.lua_pushvalue(lua_state, dbus_table);
    c.lua_call(lua_state, 2, 1);
    c.lua_setfield(lua_state, c.LUA_REGISTRYINDEX, method_dispatch_registry_key);
}

const method_dispatch_registry_key: [*:0]const u8 = "keywork.dbus.method_dispatch";

const embedded_dbus_source = @embedFile("dbus.lua");

const pop = lua_value.pop;
const absoluteIndex = lua_value.absoluteIndex;
const expectType = lua_value.expectType;
const stringField = lua_value.stringField;
const boolField = lua_value.boolField;
const stringFromStack = lua_value.stringFromStack;
const dupeStringFromStack = lua_value.dupeStringFromStack;

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

const Subscription = struct {
    bus: *Bus,
    stream: lua_coro.Stream = .{},
    handle_ref: c_int = -1,
    match_rule: ?[:0]const u8 = null,
    sender: ?[]const u8 = null,
    path: ?[]const u8 = null,
    path_namespace: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    canceled: bool = false,

    pub fn cancel(self: *Subscription, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        if (self.canceled) return;
        self.canceled = true;
        if (self.match_rule) |rule| {
            if (!self.bus.closed) dbus_c.dbus_bus_remove_match(self.bus.connection, rule.ptr, null);
        }
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
        // End the stream last so a resumed reader observes the subscription
        // already canceled and its handle dead.
        self.stream.cancel(self.bus.host.allocator(), lua_state, mode);
    }

    fn deinit(self: *Subscription, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        _ = lua_state;
        if (self.match_rule) |rule| allocator.free(rule);
        if (self.sender) |value| allocator.free(value);
        if (self.path) |value| allocator.free(value);
        if (self.path_namespace) |value| allocator.free(value);
        if (self.interface) |value| allocator.free(value);
        if (self.member) |value| allocator.free(value);
    }

    fn destroy(self: *Subscription, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.cancel(lua_state, .silent);
        self.deinit(allocator, lua_state);
        allocator.destroy(self);
    }

    fn matches(self: *const Subscription, message: *dbus_c.DBusMessage) bool {
        if (self.canceled) return false;
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
    handle_ref: c_int = -1,
    released: bool = false,

    fn release(self: *OwnedName) void {
        if (self.released) return;
        self.released = true;
        if (!self.bus.closed) _ = dbus_c.dbus_bus_release_name(self.bus.connection, self.name.ptr, null);
        lua_handle.invalidate(self.bus.host.luaState(), self.handle_ref);
        self.handle_ref = -1;
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
    handle_ref: c_int = -1,
    unexported: bool = false,

    fn unexport(self: *ExportedObject, lua_state: *c.lua_State) void {
        if (self.unexported) return;
        self.unexported = true;
        if (self.ref >= 0) {
            c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, self.ref);
            self.ref = -1;
        }
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
    }

    fn destroy(self: *ExportedObject, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.unexport(lua_state);
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

/// One consumer's claim on a shared bus connection. dbus.session() and
/// dbus.system() hand out a lease per call over a per-kind pooled Bus;
/// bus:close() (or cancellation of the acquiring task) releases only that
/// lease, and the connection closes when the last lease goes. Lease memory
/// is owned by the Bus and freed at Bus deinit.
const BusLease = struct {
    bus: *Bus,
    handle_ref: c_int = -1,
    released: bool = false,

    fn release(self: *BusLease, lua_state: *c.lua_State) void {
        if (self.released) return;
        self.released = true;
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
        std.debug.assert(self.bus.refs > 0);
        self.bus.refs -= 1;
        if (self.bus.refs == 0) self.bus.close();
    }
};

/// An unanswered incoming method call. Created when an exported method is
/// dispatched to its handler task and completed by the task through the
/// handle's reply/fail methods, whenever the handler finishes. Bus close
/// invalidates the handle, so a late completion is a no-op.
const PendingReply = struct {
    bus: *Bus,
    /// The incoming call message, ref'd for the lifetime of the handler.
    message: *dbus_c.DBusMessage,
    handle_ref: c_int = -1,

    /// Drops the handle and message without sending anything.
    fn destroy(self: *PendingReply, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
        dbus_c.dbus_message_unref(self.message);
        allocator.destroy(self);
    }
};

const Call = struct {
    bus: *Bus,
    /// Registry ref of the coroutine parked on this call, or -1 while the
    /// call is still being armed.
    ref: c_int = -1,
    pending: ?*dbus_c.DBusPendingCall = null,
    completed: bool = false,

    /// Resumes the parked caller with the reply table, or nil and an error
    /// name. Destroying an uncompleted call (bus close, teardown) never
    /// resumes: the await simply never returns and the coroutine becomes
    /// collectible once the ref is dropped.
    fn complete(self: *Call) void {
        if (self.completed) return;
        self.completed = true;
        if (self.ref < 0) return;

        const lua_state = self.bus.host.luaState();
        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, self.ref);
        const thread = c.lua_tothread(lua_state, -1).?;
        pop(lua_state, 1);

        const reply = if (self.pending) |pending| dbus_c.dbus_pending_call_steal_reply(pending) else null;
        if (reply) |message| {
            defer dbus_c.dbus_message_unref(message);
            if (dbus_c.dbus_message_get_type(message) == dbus_c.DBUS_MESSAGE_TYPE_ERROR) {
                c.lua_pushnil(thread);
                pushOptionalDbusString(thread, dbus_c.dbus_message_get_error_name(message));
                lua_coro.resumeThread(thread, 2);
            } else {
                pushDbusReply(thread, message);
                lua_coro.resumeThread(thread, 1);
            }
        } else {
            c.lua_pushnil(thread);
            c.lua_pushliteral(thread, "dbus call failed");
            lua_coro.resumeThread(thread, 2);
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
    pending_replies: std.ArrayList(*PendingReply) = .empty,
    owned_names: std.ArrayList(*OwnedName) = .empty,
    exported_objects: std.ArrayList(*ExportedObject) = .empty,
    leases: std.ArrayList(*BusLease) = .empty,
    /// Count of unreleased leases; the connection closes when it hits zero.
    refs: usize = 0,
    registered: bool = false,
    closed: bool = false,
    /// True while dbus_connection_dispatch is on the C stack.
    dispatching: bool = false,
    /// Set when close() ran during dispatch; dispatch() finishes the
    /// connection teardown once libdbus unwinds.
    pending_close: bool = false,
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
        // Drop parked readers without resuming them: close may already be
        // on the C stack of a resumed waiter (see pending calls below).
        for (self.subscriptions.items) |subscription| subscription.cancel(lua_state, .silent);
        for (self.owned_names.items) |name| name.release();
        for (self.exported_objects.items) |object| object.unexport(lua_state);

        // A call whose resumed waiter closes this bus is already on the C
        // stack. Leave that one for dbusCallNotify to remove after the
        // resume returns; all other pending calls can be canceled now,
        // which drops their waiters without resuming them.
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

        // Handler tasks still running keep dead handles; their eventual
        // reply/fail calls become no-ops instead of touching a closed
        // connection.
        for (self.pending_replies.items) |pending| pending.destroy(self.host.allocator(), lua_state);
        self.pending_replies.clearRetainingCapacity();

        if (self.filter_installed) {
            dbus_c.dbus_connection_remove_filter(self.connection, dbusFilter, self);
            self.filter_installed = false;
        }
        self.closed = true;

        // Close may come from teardown rather than the last lease release;
        // kill surviving lease handles so their methods no-op, and stop
        // handing this bus out of the pool.
        for (self.leases.items) |lease| {
            lease.released = true;
            lua_handle.invalidate(lua_state, lease.handle_ref);
            lease.handle_ref = -1;
        }
        self.refs = 0;
        clearSharedBus(lua_state, self);

        // When close is triggered by a coroutine resumed from inside
        // dbus_connection_dispatch, the connection must stay alive until
        // libdbus unwinds; dispatch() finishes the job.
        if (self.dispatching) {
            self.pending_close = true;
            return;
        }
        self.finishClose();
    }

    fn finishClose(self: *Bus) void {
        self.pending_close = false;
        dbus_c.dbus_connection_close(self.connection);
        dbus_c.dbus_connection_unref(self.connection);
        self.fd = invalid_fd;
    }

    fn deinit(self: *Bus, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.close();
        for (self.leases.items) |lease| allocator.destroy(lease);
        self.leases.deinit(allocator);
        for (self.exported_objects.items) |object| object.destroy(allocator, lua_state);
        self.exported_objects.deinit(allocator);
        for (self.owned_names.items) |name| name.destroy(allocator);
        self.owned_names.deinit(allocator);
        for (self.subscriptions.items) |subscription| subscription.destroy(allocator, lua_state);
        self.subscriptions.deinit(allocator);
        for (self.pending_calls.items) |pending_call| pending_call.destroy(allocator, lua_state);
        self.pending_calls.deinit(allocator);
        for (self.pending_replies.items) |pending| pending.destroy(allocator, lua_state);
        self.pending_replies.deinit(allocator);
    }

    pub fn destroy(self: *Bus, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        self.deinit(allocator, lua_state);
        allocator.destroy(self);
    }

    fn subscribe(self: *Bus, lua_state: *c.lua_State, options_index: c_int) !*Subscription {
        const subscription = try self.host.allocator().create(Subscription);
        errdefer self.host.allocator().destroy(subscription);

        subscription.* = .{
            .bus = self,
            .sender = try optionalStringFieldDupe(lua_state, self.host.allocator(), options_index, "sender"),
            .path = try optionalStringFieldDupe(lua_state, self.host.allocator(), options_index, "path"),
            .path_namespace = try optionalStringFieldDupe(lua_state, self.host.allocator(), options_index, "path_namespace"),
            .interface = try optionalStringFieldDupe(lua_state, self.host.allocator(), options_index, "interface"),
            .member = try optionalStringFieldDupe(lua_state, self.host.allocator(), options_index, "member"),
        };
        errdefer subscription.deinit(self.host.allocator(), lua_state);
        subscription.match_rule = try buildDbusMatchRule(self.host.allocator(), subscription);
        dbus_c.dbus_bus_add_match(self.connection, subscription.match_rule.?.ptr, null);

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

    /// Sends a method call and arms its completion to resume the coroutine
    /// behind `thread_ref`. Takes ownership of `thread_ref` even on failure.
    fn call(self: *Bus, lua_state: *c.lua_State, options_index: c_int, thread_ref: c_int) !void {
        errdefer c.luaL_unref(lua_state, c.LUA_REGISTRYINDEX, thread_ref);
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
        call_state.* = .{ .bus = self };
        errdefer call_state.deinit(lua_state);

        var pending: ?*dbus_c.DBusPendingCall = null;
        if (dbus_c.dbus_connection_send_with_reply(self.connection, message, &pending, @intCast(timeout_ms)) == 0) return error.OutOfMemory;
        call_state.pending = pending orelse return error.DBusCallFailed;

        try self.pending_calls.append(self.host.allocator(), call_state);
        errdefer _ = self.removePendingCall(call_state);
        if (dbus_c.dbus_pending_call_set_notify(call_state.pending, dbusCallNotify, call_state, null) == 0) return error.OutOfMemory;
        // The ref transfers only once nothing can fail, so the errdefer
        // above and the call's deinit never unref twice.
        call_state.ref = thread_ref;
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
        // A dispatched message may resume a coroutine that closes this bus
        // (e.g. releasing the last lease); close() then defers the real
        // connection teardown to here, after libdbus is off the C stack.
        self.dispatching = true;
        defer {
            self.dispatching = false;
            if (self.pending_close) self.finishClose();
        }
        _ = dbus_c.dbus_connection_read_write(self.connection, 0);
        while (!self.pending_close and
            dbus_c.dbus_connection_dispatch(self.connection) == dbus_c.DBUS_DISPATCH_DATA_REMAINS)
        {}
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
            pushDbusSignal(lua_state, message);
            try subscription.stream.deliver(self.host.allocator(), lua_state);
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
        const handler_index = c.lua_gettop(lua_state);

        std.log.scoped(.keywork_luajit).info("dbus method call {s}.{s}", .{ interface, member });

        // The handler runs on its own task so it can yield; the pending
        // reply completes whenever the task finishes. loop.spawn is eager,
        // so a handler that never yields replies before dispatch returns.
        const allocator = self.host.allocator();
        const pending = try allocator.create(PendingReply);
        _ = dbus_c.dbus_message_ref(message);
        pending.* = .{ .bus = self, .message = message };
        self.pending_replies.append(allocator, pending) catch |err| {
            dbus_c.dbus_message_unref(message);
            allocator.destroy(pending);
            return err;
        };

        c.lua_getfield(lua_state, c.LUA_REGISTRYINDEX, method_dispatch_registry_key);
        pending.handle_ref = lua_handle.create(lua_state, pending_reply_type, &pending_reply_methods, pending);
        c.lua_pushvalue(lua_state, handler_index);
        pushCallTable(lua_state, message);
        const arg_count = pushDbusMessageArgs(lua_state, message);
        if (c.lua_pcall(lua_state, @intCast(arg_count + 3), 0, 0) != 0) {
            const error_message = stringFromStack(lua_state, -1) catch "Lua D-Bus method dispatch failed";
            // The handler task may already have completed (and destroyed)
            // the pending reply before the dispatcher failed; only a
            // still-listed pending is ours to clean up. The caller's own
            // message ref keeps `message` valid past the destroy.
            if (self.removePendingReply(pending)) pending.destroy(allocator, lua_state);
            try self.replyError(message, "org.keywork.LuaError", error_message);
            return true;
        }
        return true;
    }

    /// Unlinks a pending reply from the bus; returns false when it was
    /// already completed and destroyed.
    fn removePendingReply(self: *Bus, pending: *PendingReply) bool {
        for (self.pending_replies.items, 0..) |item, index| {
            if (item == pending) {
                _ = self.pending_replies.swapRemove(index);
                return true;
            }
        }
        return false;
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
        } else if (std.mem.eql(u8, member, "Set")) {
            const pair = methodCallStringPair(message) orelse {
                try self.replyError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Set requires interface, property, and value");
                return;
            };
            try self.replyPropertySet(object, message, pair.interface, pair.property);
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

    /// Handles org.freedesktop.DBus.Properties.Set: unwraps the variant
    /// into a Lua value, invokes the exported property's `set` function,
    /// and replies with an empty method return. Properties without a `set`
    /// function are read-only.
    fn replyPropertySet(self: *Bus, object: *ExportedObject, message: *dbus_c.DBusMessage, interface: []const u8, property: []const u8) !void {
        const lua_state = self.host.luaState();
        const original_top = c.lua_gettop(lua_state);
        defer c.lua_settop(lua_state, original_top);

        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, object.ref);
        c.lua_getfield(lua_state, -1, tryZTemp(interface).ptr);
        if (c.lua_isnil(lua_state, -1)) {
            try self.replyError(message, "org.freedesktop.DBus.Error.UnknownInterface", "unknown interface");
            return;
        }
        c.lua_getfield(lua_state, -1, "properties");
        if (!c.lua_isnil(lua_state, -1)) c.lua_getfield(lua_state, -1, tryZTemp(property).ptr);
        if (c.lua_isnil(lua_state, -1)) {
            try self.replyError(message, "org.freedesktop.DBus.Error.UnknownProperty", "unknown property");
            return;
        }
        c.lua_getfield(lua_state, -1, "set");
        if (c.lua_type(lua_state, -1) != c.LUA_TFUNCTION) {
            try self.replyError(message, "org.freedesktop.DBus.Error.PropertyReadOnly", "property is read-only");
            return;
        }
        if (!pushMethodCallArg(lua_state, message, 2)) {
            try self.replyError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Set requires a value");
            return;
        }
        if (c.lua_pcall(lua_state, 1, 0, 0) != 0) {
            const error_message = stringFromStack(lua_state, -1) catch "Lua property setter failed";
            try self.replyError(message, "org.keywork.LuaError", error_message);
            return;
        }
        try self.replyValues(message, lua_state, original_top, 0);
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
    call.complete();
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

fn sharedBusRegistryKey(kind: Kind) [*:0]const u8 {
    return switch (kind) {
        .session => "keywork.dbus.shared_session",
        .system => "keywork.dbus.shared_system",
    };
}

/// Returns the pooled bus for `kind`, or null when none is open.
fn sharedBus(lua_state: *c.lua_State, kind: Kind) ?*Bus {
    c.lua_getfield(lua_state, c.LUA_REGISTRYINDEX, sharedBusRegistryKey(kind));
    defer pop(lua_state, 1);
    const ptr = c.lua_touserdata(lua_state, -1) orelse return null;
    const bus: *Bus = @ptrCast(@alignCast(ptr));
    if (bus.closed) return null;
    return bus;
}

fn setSharedBus(lua_state: *c.lua_State, kind: Kind, bus: *Bus) void {
    c.lua_pushlightuserdata(lua_state, bus);
    c.lua_setfield(lua_state, c.LUA_REGISTRYINDEX, sharedBusRegistryKey(kind));
}

/// Removes `bus` from the pool if it is the one being handed out.
fn clearSharedBus(lua_state: *c.lua_State, bus: *Bus) void {
    const key = sharedBusRegistryKey(bus.kind);
    c.lua_getfield(lua_state, c.LUA_REGISTRYINDEX, key);
    const current = c.lua_touserdata(lua_state, -1);
    pop(lua_state, 1);
    if (current != @as(*anyopaque, bus)) return;
    c.lua_pushnil(lua_state);
    c.lua_setfield(lua_state, c.LUA_REGISTRYINDEX, key);
}

fn luaBus(lua_state_optional: ?*c.lua_State, kind: Kind) c_int {
    const lua_state = lua_state_optional.?;
    const host = hostFromLua(lua_state);
    lua_task.raiseIfCanceled(lua_state);
    // A missing session or system bus is an expected runtime condition, so
    // connection failure reports nil, err instead of raising.
    const bus = sharedBus(lua_state, kind) orelse blk: {
        const created = host.addBus(kind) catch |err| {
            std.log.scoped(.keywork_luajit).warn("dbus bus failed: {}", .{err});
            c.lua_pushnil(lua_state);
            const name = @errorName(err);
            c.lua_pushlstring(lua_state, name.ptr, name.len);
            return 2;
        };
        setSharedBus(lua_state, kind, created);
        break :blk created;
    };

    const allocator = host.allocator();
    const lease = allocator.create(BusLease) catch |err| {
        c.lua_pushnil(lua_state);
        const name = @errorName(err);
        c.lua_pushlstring(lua_state, name.ptr, name.len);
        return 2;
    };
    lease.* = .{ .bus = bus };
    bus.leases.append(allocator, lease) catch |err| {
        allocator.destroy(lease);
        c.lua_pushnil(lua_state);
        const name = @errorName(err);
        c.lua_pushlstring(lua_state, name.ptr, name.len);
        return 2;
    };
    bus.refs += 1;
    lua_task.adopt(lua_state, .{ .ptr = lease, .cancel_fn = cancelBusLease });
    lease.handle_ref = lua_handle.create(lua_state, bus_type, &bus_methods, lease);
    return 1;
}

/// Task-cancel hook: releasing a lease never resumes parked readers (a
/// last-lease release closes the bus, which drops them silently), so both
/// cancel modes are safe here.
fn cancelBusLease(ptr: *anyopaque, lua_state: *c.lua_State, _: lua_coro.CancelMode) void {
    const lease: *BusLease = @ptrCast(@alignCast(ptr));
    lease.release(lua_state);
}

/// Derefs a lease handle at `index` to its bus, or null when the lease was
/// released or the bus closed.
fn leasedBus(lua_state: *c.lua_State, index: c_int) ?*Bus {
    const lease = lua_handle.resource(BusLease, lua_state, index, bus_type) orelse return null;
    return lease.bus;
}

fn luaDbusSubscribe(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus = leasedBus(lua_state, 1) orelse return 0;
    lua_task.raiseIfCanceled(lua_state);
    c.luaL_checktype(lua_state, 2, c.LUA_TTABLE);
    const subscription = bus.subscribe(lua_state, 2) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus subscribe failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus subscribe failed");
    };
    lua_task.adoptResource(Subscription, lua_state, subscription);
    subscription.handle_ref = lua_handle.create(lua_state, subscription_type, &subscription_methods, subscription);
    return 1;
}

fn luaCall(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus = leasedBus(lua_state, 1) orelse {
        // An awaited call needs a distinguishable result, so a dead bus
        // handle reports nil, err instead of the usual silent no-op.
        c.lua_pushnil(lua_state);
        c.lua_pushliteral(lua_state, "BusClosed");
        return 2;
    };
    c.luaL_checktype(lua_state, 2, c.LUA_TTABLE);
    if (lua_coro.onMainThread(lua_state)) return c.luaL_error(lua_state, "bus:call must be called from a coroutine (wrap the caller in loop.spawn)");
    // Sending on a disconnected bus is an expected runtime condition and
    // reports nil, err; bad options and allocation failures still raise.
    // Method-call errors from the peer resume the caller as nil, error_name.
    const ref = lua_coro.refCurrentThread(lua_state);
    bus.call(lua_state, 2, ref) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus call failed: {}", .{err});
        if (err != error.DBusCallFailed) return c.luaL_error(lua_state, "dbus call failed");
        c.lua_pushnil(lua_state);
        const name = @errorName(err);
        c.lua_pushlstring(lua_state, name.ptr, name.len);
        return 2;
    };
    return c.lua_yield(lua_state, 0);
}

fn luaDbusRequestName(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus = leasedBus(lua_state, 1) orelse return 0;
    _ = c.luaL_checklstring(lua_state, 2, null);
    // Losing the race for a bus name is an expected runtime condition, so
    // an unavailable name reports nil, err instead of raising.
    const owned = bus.requestName(lua_state, 2) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus request_name failed: {}", .{err});
        if (err != error.DBusNameUnavailable) return c.luaL_error(lua_state, "dbus request_name failed");
        c.lua_pushnil(lua_state);
        const name = @errorName(err);
        c.lua_pushlstring(lua_state, name.ptr, name.len);
        return 2;
    };
    owned.handle_ref = lua_handle.create(lua_state, owned_name_type, &owned_name_methods, owned);
    return 1;
}

fn luaDbusReleaseName(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus = leasedBus(lua_state, 1) orelse return 0;
    const name = stringFromStack(lua_state, 2) catch return c.luaL_error(lua_state, "release_name requires a name");
    bus.releaseName(name);
    return 0;
}

fn luaDbusExport(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus = leasedBus(lua_state, 1) orelse return 0;
    const object = bus.exportObject(lua_state, 2, 3) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus export failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus export failed");
    };
    object.handle_ref = lua_handle.create(lua_state, export_type, &export_methods, object);
    return 1;
}

fn luaDbusEmit(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus = leasedBus(lua_state, 1) orelse return 0;
    c.luaL_checktype(lua_state, 2, c.LUA_TTABLE);
    bus.emitSignal(lua_state, 2) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus emit failed: {}", .{err});
        return c.luaL_error(lua_state, "dbus emit failed");
    };
    return 0;
}

fn luaDbusClose(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const lease = lua_handle.resource(BusLease, lua_state, 1, bus_type) orelse return 0;
    lease.release(lua_state);
    return 0;
}

/// The connection's unique bus name (e.g. ":1.42"). Needed by protocols
/// that derive object paths from the caller's name, such as the XDG
/// desktop portal request pattern.
fn luaDbusUniqueName(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus = leasedBus(lua_state, 1) orelse {
        c.lua_pushnil(lua_state);
        c.lua_pushlstring(lua_state, "closed", "closed".len);
        return 2;
    };
    const name = dbus_c.dbus_bus_get_unique_name(bus.connection) orelse {
        c.lua_pushnil(lua_state);
        c.lua_pushlstring(lua_state, "no unique name", "no unique name".len);
        return 2;
    };
    const span = std.mem.span(name);
    c.lua_pushlstring(lua_state, span.ptr, span.len);
    return 1;
}

fn luaDbusClosed(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const bus = leasedBus(lua_state, 1) orelse {
        c.lua_pushboolean(lua_state, 1);
        return 1;
    };
    c.lua_pushboolean(lua_state, if (bus.closed) 1 else 0);
    return 1;
}

const bus_type: [*:0]const u8 = "keywork.dbus_bus";
const bus_methods = [_]lua_handle.Method{
    .{ .name = "subscribe", .func = luaDbusSubscribe },
    .{ .name = "call", .func = luaCall },
    .{ .name = "request_name", .func = luaDbusRequestName },
    .{ .name = "release_name", .func = luaDbusReleaseName },
    .{ .name = "export", .func = luaDbusExport },
    .{ .name = "emit", .func = luaDbusEmit },
    .{ .name = "close", .func = luaDbusClose },
    .{ .name = "closed", .func = luaDbusClosed },
    .{ .name = "unique_name", .func = luaDbusUniqueName },
};

const subscription_type: [*:0]const u8 = "keywork.dbus_subscription";
const subscription_methods = [_]lua_handle.Method{
    .{ .name = "next", .func = luaSubscriptionNext },
    .{ .name = "events", .func = luaSubscriptionEvents },
    .{ .name = "cancel", .func = luaCancelSubscription },
};

const owned_name_type: [*:0]const u8 = "keywork.dbus_name";
const owned_name_methods = [_]lua_handle.Method{
    .{ .name = "release", .func = luaReleaseOwnedName },
};

const export_type: [*:0]const u8 = "keywork.dbus_export";
const export_methods = [_]lua_handle.Method{
    .{ .name = "unexport", .func = luaUnexportDbusObject },
};

const pending_reply_type: [*:0]const u8 = "keywork.dbus_pending_reply";
const pending_reply_methods = [_]lua_handle.Method{
    .{ .name = "reply", .func = luaPendingReplySend },
    .{ .name = "fail", .func = luaPendingReplyFail },
};

/// Sends the method return built from the call's stack values (index 2
/// onward) and retires the pending reply. No-op on a dead handle.
fn luaPendingReplySend(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const pending = lua_handle.resource(PendingReply, lua_state, 1, pending_reply_type) orelse return 0;
    const bus = pending.bus;
    const top = c.lua_gettop(lua_state);
    const count: usize = if (top > 1) @intCast(top - 1) else 0;
    bus.replyValues(pending.message, lua_state, 2, count) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus method reply failed: {}", .{err});
        // The values did not encode; an error reply keeps the caller from
        // hanging until its timeout.
        bus.replyError(pending.message, "org.keywork.LuaError", "failed to encode method reply") catch {};
    };
    _ = bus.removePendingReply(pending);
    pending.destroy(bus.host.allocator(), lua_state);
    return 0;
}

/// Sends an org.keywork.LuaError reply carrying the handler's error text
/// and retires the pending reply. No-op on a dead handle.
fn luaPendingReplyFail(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const pending = lua_handle.resource(PendingReply, lua_state, 1, pending_reply_type) orelse return 0;
    const bus = pending.bus;
    const text = stringFromStack(lua_state, 2) catch "Lua D-Bus method failed";
    bus.replyError(pending.message, "org.keywork.LuaError", text) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus method error reply failed: {}", .{err});
    };
    _ = bus.removePendingReply(pending);
    pending.destroy(bus.host.allocator(), lua_state);
    return 0;
}

fn luaCancelSubscription(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const subscription = lua_handle.resource(Subscription, lua_state, 1, subscription_type) orelse return 0;
    subscription.cancel(lua_state, .resume_reader);
    return 0;
}

fn luaSubscriptionNext(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    // A dead handle ends the iteration instead of parking forever.
    const subscription = lua_handle.resource(Subscription, lua_state, 1, subscription_type) orelse return 0;
    return subscription.stream.awaitNext(lua_state, subscription.canceled);
}

fn luaSubscriptionEvents(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    _ = c.luaL_checkudata(lua_state, 1, subscription_type);
    return lua_coro.pushIterator(lua_state, luaSubscriptionNext);
}

fn luaReleaseOwnedName(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const owned = lua_handle.resource(OwnedName, lua_state, 1, owned_name_type) orelse return 0;
    owned.release();
    return 0;
}

fn luaUnexportDbusObject(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    const object = lua_handle.resource(ExportedObject, lua_state, 1, export_type) orelse return 0;
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
    if (signature[0] == '(') return appendStructWithSignature(lua_state, index, signature, iter);
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
    if (element_signature.len > 0 and element_signature[0] == '{') {
        try appendDictEntries(lua_state, table, element_signature, &array);
    } else {
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
    }
    if (dbus_c.dbus_message_iter_close_container(iter, &array) == 0) return error.OutOfMemory;
}

/// Appends a Lua map as D-Bus dict entries. `element_signature` is the
/// full entry signature including braces (e.g. `{sv}`).
fn appendDictEntries(lua_state: *c.lua_State, table: c_int, element_signature: []const u8, array: *dbus_c.DBusMessageIter) !void {
    if (element_signature.len < 4 or element_signature[element_signature.len - 1] != '}') return error.InvalidDbusSignature;
    const inner = element_signature[1 .. element_signature.len - 1];
    const key_length = try signatureElementLength(inner);
    const key_signature = inner[0..key_length];
    const value_signature = inner[key_length..];
    if (value_signature.len != try signatureElementLength(value_signature)) return error.InvalidDbusSignature;

    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, table) != 0) {
        var entry: dbus_c.DBusMessageIter = undefined;
        if (dbus_c.dbus_message_iter_open_container(array, dbus_c.DBUS_TYPE_DICT_ENTRY, null, &entry) == 0) return error.OutOfMemory;
        // Append a copy of the key: serializing may lua_tolstring it,
        // and converting the original in place would corrupt lua_next.
        c.lua_pushvalue(lua_state, -2);
        try appendLuaValueWithSignature(lua_state, -1, key_signature, &entry);
        pop(lua_state, 1);
        try appendLuaValueWithSignature(lua_state, -1, value_signature, &entry);
        if (dbus_c.dbus_message_iter_close_container(array, &entry) == 0) return error.OutOfMemory;
        pop(lua_state, 1);
    }
}

/// Appends a positional Lua sequence as a D-Bus struct. `signature`
/// includes the surrounding parentheses (e.g. `(sa(us))`).
fn appendStructWithSignature(lua_state: *c.lua_State, index: c_int, signature: []const u8, iter: *dbus_c.DBusMessageIter) !void {
    if (signature.len < 3 or signature[signature.len - 1] != ')') return error.InvalidDbusSignature;
    try expectType(lua_state, index, c.LUA_TTABLE);
    const table = absoluteIndex(lua_state, index);
    var strukt: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_open_container(iter, dbus_c.DBUS_TYPE_STRUCT, null, &strukt) == 0) return error.OutOfMemory;
    const fields = signature[1 .. signature.len - 1];
    var offset: usize = 0;
    var item_index: c_int = 1;
    while (offset < fields.len) : (item_index += 1) {
        const field_length = try signatureElementLength(fields[offset..]);
        c.lua_rawgeti(lua_state, table, item_index);
        defer pop(lua_state, 1);
        try appendLuaValueWithSignature(lua_state, -1, fields[offset..][0..field_length], &strukt);
        offset += field_length;
    }
    if (dbus_c.dbus_message_iter_close_container(iter, &strukt) == 0) return error.OutOfMemory;
}

/// Length of the first complete single type in a D-Bus signature.
fn signatureElementLength(signature: []const u8) error{InvalidDbusSignature}!usize {
    if (signature.len == 0) return error.InvalidDbusSignature;
    return switch (signature[0]) {
        'a' => 1 + try signatureElementLength(signature[1..]),
        '(' => try matchedContainerLength(signature, '(', ')'),
        '{' => try matchedContainerLength(signature, '{', '}'),
        else => 1,
    };
}

fn matchedContainerLength(signature: []const u8, open: u8, close: u8) error{InvalidDbusSignature}!usize {
    var depth: usize = 0;
    for (signature, 0..) |char, char_index| {
        if (char == open) depth += 1;
        if (char == close) {
            if (depth == 0) return error.InvalidDbusSignature;
            depth -= 1;
            if (depth == 0) return char_index + 1;
        }
    }
    return error.InvalidDbusSignature;
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

/// Pushes method-call argument `wanted_index` (0-based) as a Lua value, or
/// returns false when the message has too few arguments. Variants decode
/// transparently like all other incoming values.
fn pushMethodCallArg(lua_state: *c.lua_State, message: *dbus_c.DBusMessage, wanted_index: usize) bool {
    var iter: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_init(message, &iter) == 0) return false;
    var index: usize = 0;
    while (index < wanted_index) : (index += 1) {
        if (dbus_c.dbus_message_iter_next(&iter) == 0) return false;
    }
    if (dbus_c.dbus_message_iter_get_arg_type(&iter) == dbus_c.DBUS_TYPE_INVALID) return false;
    pushDbusIterValue(lua_state, &iter);
    return true;
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
    try writeDbusSignatureArgs(writer, signature, direction);
}

fn writeDbusSignatureArgs(writer: *std.Io.Writer, signature: []const u8, direction: ?[]const u8) !void {
    var offset: usize = 0;
    while (offset < signature.len) {
        const length = try signatureElementLength(signature[offset..]);
        const arg_signature = signature[offset..][0..length];
        if (direction) |dir| {
            try writer.print("      <arg type=\"{s}\" direction=\"{s}\"/>\n", .{ arg_signature, dir });
        } else {
            try writer.print("      <arg type=\"{s}\"/>\n", .{arg_signature});
        }
        offset += length;
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
        dbus_c.DBUS_TYPE_ARRAY => {
            if (dbus_c.dbus_message_iter_get_element_type(iter) == dbus_c.DBUS_TYPE_DICT_ENTRY) {
                pushDbusIterDict(lua_state, iter);
            } else if (dbus_c.dbus_message_iter_get_element_type(iter) == dbus_c.DBUS_TYPE_BYTE) {
                pushDbusIterByteArray(lua_state, iter);
            } else {
                pushDbusIterSequence(lua_state, iter);
            }
        },
        dbus_c.DBUS_TYPE_STRUCT, dbus_c.DBUS_TYPE_DICT_ENTRY => pushDbusIterSequence(lua_state, iter),
        else => c.lua_pushnil(lua_state),
    }
}

fn pushDbusIterByteArray(lua_state: *c.lua_State, iter: *dbus_c.DBusMessageIter) void {
    var elements: dbus_c.DBusMessageIter = undefined;
    dbus_c.dbus_message_iter_recurse(iter, &elements);
    var bytes: [*c]const u8 = null;
    var count: c_int = 0;
    dbus_c.dbus_message_iter_get_fixed_array(&elements, @ptrCast(&bytes), &count);
    if (count <= 0) {
        c.lua_pushliteral(lua_state, "");
    } else {
        c.lua_pushlstring(lua_state, bytes, @intCast(count));
    }
}

/// Decodes a D-Bus dictionary (an array of dict entries, e.g. `a{sv}`)
/// into a Lua map keyed by the entry keys instead of a positional array
/// of `{key, value}` pairs.
fn pushDbusIterDict(lua_state: *c.lua_State, iter: *dbus_c.DBusMessageIter) void {
    c.lua_createtable(lua_state, 0, 0);
    const table = c.lua_gettop(lua_state);
    var entries: dbus_c.DBusMessageIter = undefined;
    dbus_c.dbus_message_iter_recurse(iter, &entries);
    while (dbus_c.dbus_message_iter_get_arg_type(&entries) != dbus_c.DBUS_TYPE_INVALID) {
        var entry: dbus_c.DBusMessageIter = undefined;
        dbus_c.dbus_message_iter_recurse(&entries, &entry);
        pushDbusIterValue(lua_state, &entry);
        // Keys are basic D-Bus types, so nil only appears on malformed
        // input; nil keys are illegal in Lua tables, so drop the entry.
        if (c.lua_isnil(lua_state, -1)) {
            pop(lua_state, 1);
        } else if (dbus_c.dbus_message_iter_next(&entry) != 0) {
            pushDbusIterValue(lua_state, &entry);
            c.lua_settable(lua_state, table);
        } else {
            pop(lua_state, 1);
        }
        if (dbus_c.dbus_message_iter_next(&entries) == 0) break;
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

fn tryZTemp(value: []const u8) [:0]const u8 {
    std.debug.assert(value.len < dbus_temp_z_buffers[0].len);
    const slot = dbus_temp_z_slot % dbus_temp_z_buffers.len;
    dbus_temp_z_slot +%= 1;
    @memcpy(dbus_temp_z_buffers[slot][0..value.len], value);
    dbus_temp_z_buffers[slot][value.len] = 0;
    return dbus_temp_z_buffers[slot][0..value.len :0];
}

fn testAppendVariantString(entry: *dbus_c.DBusMessageIter, value: [*:0]const u8) !void {
    var variant: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_open_container(entry, dbus_c.DBUS_TYPE_VARIANT, "s", &variant) == 0) return error.OutOfMemory;
    var ptr = value;
    try appendDbusBasic(&variant, dbus_c.DBUS_TYPE_STRING, &ptr);
    if (dbus_c.dbus_message_iter_close_container(entry, &variant) == 0) return error.OutOfMemory;
}

fn testAppendDictEntryString(array: *dbus_c.DBusMessageIter, key: [*:0]const u8, value: [*:0]const u8) !void {
    var entry: dbus_c.DBusMessageIter = undefined;
    if (dbus_c.dbus_message_iter_open_container(array, dbus_c.DBUS_TYPE_DICT_ENTRY, null, &entry) == 0) return error.OutOfMemory;
    var key_ptr = key;
    try appendDbusBasic(&entry, dbus_c.DBUS_TYPE_STRING, &key_ptr);
    try testAppendVariantString(&entry, value);
    if (dbus_c.dbus_message_iter_close_container(array, &entry) == 0) return error.OutOfMemory;
}

test signatureElementLength {
    try std.testing.expectEqual(@as(usize, 1), try signatureElementLength("s"));
    try std.testing.expectEqual(@as(usize, 2), try signatureElementLength("as"));
    try std.testing.expectEqual(@as(usize, 8), try signatureElementLength("(sa(us))"));
    try std.testing.expectEqual(@as(usize, 4), try signatureElementLength("{sv}x"));
    try std.testing.expectError(error.InvalidDbusSignature, signatureElementLength("(s"));
    try std.testing.expectError(error.InvalidDbusSignature, signatureElementLength(""));
}

test "dbus introspection writes one argument per complete type" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeDbusSignatureArgs(&output.writer, "susssasa{sv}i", "in");
    try std.testing.expectEqualStrings(
        \\      <arg type="s" direction="in"/>
        \\      <arg type="u" direction="in"/>
        \\      <arg type="s" direction="in"/>
        \\      <arg type="s" direction="in"/>
        \\      <arg type="s" direction="in"/>
        \\      <arg type="as" direction="in"/>
        \\      <arg type="a{sv}" direction="in"/>
        \\      <arg type="i" direction="in"/>
        \\
    , output.written());
}

test "dbus dict and struct arguments encode from Lua tables" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);
    c.luaL_openlibs(lua_state);

    // Tables shaped as dbus.variant/dbus.array produce them, covering
    // the dict ({sv}) and struct ((sa(us))) paths portals and
    // notifications rely on.
    const build_script =
        \\local function variant(sig, value)
        \\  return { __dbus_type = "variant", signature = sig, value = value }
        \\end
        \\payload = {
        \\  args = {
        \\    { __dbus_type = "array", signature = "{sv}", value = {
        \\      name = variant("s", "keywork"),
        \\      count = variant("i", 7),
        \\      level = variant("y", 2),
        \\    } },
        \\    { __dbus_type = "array", signature = "(sa(us))", value = {
        \\      { "Images", { { 0, "*.png" }, { 0, "*.svg" } } },
        \\    } },
        \\  },
        \\}
    ;
    if (c.luaL_loadstring(lua_state, build_script) != 0) return error.LoadFailed;
    if (c.lua_pcall(lua_state, 0, 0, 0) != 0) return error.ScriptFailed;

    const message = dbus_c.dbus_message_new_signal("/test", "test.Interface", "Test") orelse return error.OutOfMemory;
    defer dbus_c.dbus_message_unref(message);
    var iter: dbus_c.DBusMessageIter = undefined;
    dbus_c.dbus_message_iter_init_append(message, &iter);

    c.lua_getglobal(lua_state, "payload");
    try appendDbusLuaArgs(lua_state, absoluteIndex(lua_state, -1), &iter);
    pop(lua_state, 1);

    pushDbusArgsTable(lua_state, message);
    c.lua_setglobal(lua_state, "args");

    const check_script =
        \\assert(args[1].name == "keywork")
        \\assert(args[1].count == 7)
        \\assert(args[1].level == 2)
        \\assert(args[2][1][1] == "Images")
        \\assert(args[2][1][2][1][1] == 0 and args[2][1][2][1][2] == "*.png")
        \\assert(args[2][1][2][2][2] == "*.svg")
    ;
    if (c.luaL_loadstring(lua_state, check_script) != 0) return error.LoadFailed;
    if (c.lua_pcall(lua_state, 0, 0, 0) != 0) {
        var len: usize = 0;
        const message_ptr = c.lua_tolstring(lua_state, -1, &len);
        if (message_ptr) |text| std.debug.print("script failed: {s}\n", .{text[0..len]});
        return error.ScriptFailed;
    }
}

test "dbus dicts decode to Lua maps, arrays and structs to sequences" {
    const message = dbus_c.dbus_message_new_signal("/test", "test.Interface", "Test") orelse return error.OutOfMemory;
    defer dbus_c.dbus_message_unref(message);

    var iter: dbus_c.DBusMessageIter = undefined;
    dbus_c.dbus_message_iter_init_append(message, &iter);

    // arg 1: a{sv} with a string, an int32, and a nested a{sv}.
    {
        var array: dbus_c.DBusMessageIter = undefined;
        if (dbus_c.dbus_message_iter_open_container(&iter, dbus_c.DBUS_TYPE_ARRAY, "{sv}", &array) == 0) return error.OutOfMemory;
        try testAppendDictEntryString(&array, "name", "keywork");
        {
            var entry: dbus_c.DBusMessageIter = undefined;
            if (dbus_c.dbus_message_iter_open_container(&array, dbus_c.DBUS_TYPE_DICT_ENTRY, null, &entry) == 0) return error.OutOfMemory;
            var key: [*:0]const u8 = "count";
            try appendDbusBasic(&entry, dbus_c.DBUS_TYPE_STRING, &key);
            var variant: dbus_c.DBusMessageIter = undefined;
            if (dbus_c.dbus_message_iter_open_container(&entry, dbus_c.DBUS_TYPE_VARIANT, "i", &variant) == 0) return error.OutOfMemory;
            var count: i32 = 7;
            try appendDbusBasic(&variant, dbus_c.DBUS_TYPE_INT32, &count);
            if (dbus_c.dbus_message_iter_close_container(&entry, &variant) == 0) return error.OutOfMemory;
            if (dbus_c.dbus_message_iter_close_container(&array, &entry) == 0) return error.OutOfMemory;
        }
        {
            var entry: dbus_c.DBusMessageIter = undefined;
            if (dbus_c.dbus_message_iter_open_container(&array, dbus_c.DBUS_TYPE_DICT_ENTRY, null, &entry) == 0) return error.OutOfMemory;
            var key: [*:0]const u8 = "nested";
            try appendDbusBasic(&entry, dbus_c.DBUS_TYPE_STRING, &key);
            var variant: dbus_c.DBusMessageIter = undefined;
            if (dbus_c.dbus_message_iter_open_container(&entry, dbus_c.DBUS_TYPE_VARIANT, "a{sv}", &variant) == 0) return error.OutOfMemory;
            var nested: dbus_c.DBusMessageIter = undefined;
            if (dbus_c.dbus_message_iter_open_container(&variant, dbus_c.DBUS_TYPE_ARRAY, "{sv}", &nested) == 0) return error.OutOfMemory;
            try testAppendDictEntryString(&nested, "inner", "value");
            if (dbus_c.dbus_message_iter_close_container(&variant, &nested) == 0) return error.OutOfMemory;
            if (dbus_c.dbus_message_iter_close_container(&entry, &variant) == 0) return error.OutOfMemory;
            if (dbus_c.dbus_message_iter_close_container(&array, &entry) == 0) return error.OutOfMemory;
        }
        if (dbus_c.dbus_message_iter_close_container(&iter, &array) == 0) return error.OutOfMemory;
    }

    // arg 2: plain string array stays a sequence.
    {
        var array: dbus_c.DBusMessageIter = undefined;
        if (dbus_c.dbus_message_iter_open_container(&iter, dbus_c.DBUS_TYPE_ARRAY, "s", &array) == 0) return error.OutOfMemory;
        var first: [*:0]const u8 = "x";
        var second: [*:0]const u8 = "y";
        try appendDbusBasic(&array, dbus_c.DBUS_TYPE_STRING, &first);
        try appendDbusBasic(&array, dbus_c.DBUS_TYPE_STRING, &second);
        if (dbus_c.dbus_message_iter_close_container(&iter, &array) == 0) return error.OutOfMemory;
    }

    // arg 3: struct stays a positional sequence.
    {
        var strukt: dbus_c.DBusMessageIter = undefined;
        if (dbus_c.dbus_message_iter_open_container(&iter, dbus_c.DBUS_TYPE_STRUCT, null, &strukt) == 0) return error.OutOfMemory;
        var number: i32 = 5;
        var text: [*:0]const u8 = "s";
        try appendDbusBasic(&strukt, dbus_c.DBUS_TYPE_INT32, &number);
        try appendDbusBasic(&strukt, dbus_c.DBUS_TYPE_STRING, &text);
        if (dbus_c.dbus_message_iter_close_container(&iter, &strukt) == 0) return error.OutOfMemory;
    }

    // arg 4: empty dict decodes to an empty table.
    {
        var array: dbus_c.DBusMessageIter = undefined;
        if (dbus_c.dbus_message_iter_open_container(&iter, dbus_c.DBUS_TYPE_ARRAY, "{sv}", &array) == 0) return error.OutOfMemory;
        if (dbus_c.dbus_message_iter_close_container(&iter, &array) == 0) return error.OutOfMemory;
    }

    // arg 5: byte arrays decode to strings rather than one Lua number per byte.
    {
        var array: dbus_c.DBusMessageIter = undefined;
        if (dbus_c.dbus_message_iter_open_container(&iter, dbus_c.DBUS_TYPE_ARRAY, "y", &array) == 0) return error.OutOfMemory;
        for ([_]u8{ 0, 127, 255 }) |byte| {
            var value = byte;
            try appendDbusBasic(&array, dbus_c.DBUS_TYPE_BYTE, &value);
        }
        if (dbus_c.dbus_message_iter_close_container(&iter, &array) == 0) return error.OutOfMemory;
    }

    // arg 6: empty byte arrays are empty strings, not null pointers.
    {
        var array: dbus_c.DBusMessageIter = undefined;
        if (dbus_c.dbus_message_iter_open_container(&iter, dbus_c.DBUS_TYPE_ARRAY, "y", &array) == 0) return error.OutOfMemory;
        if (dbus_c.dbus_message_iter_close_container(&iter, &array) == 0) return error.OutOfMemory;
    }

    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);
    c.luaL_openlibs(lua_state);

    pushDbusArgsTable(lua_state, message);
    c.lua_setglobal(lua_state, "args");

    const script =
        \\assert(args[1].name == "keywork")
        \\assert(args[1].count == 7)
        \\assert(args[1].nested.inner == "value")
        \\assert(args[2][1] == "x" and args[2][2] == "y")
        \\assert(args[3][1] == 5 and args[3][2] == "s")
        \\assert(type(args[4]) == "table" and next(args[4]) == nil)
        \\assert(args[5] == "\0\127\255")
        \\assert(args[6] == "")
    ;
    if (c.luaL_loadstring(lua_state, script) != 0) return error.LoadFailed;
    if (c.lua_pcall(lua_state, 0, 0, 0) != 0) {
        var len: usize = 0;
        const message_ptr = c.lua_tolstring(lua_state, -1, &len);
        if (message_ptr) |text| std.debug.print("script failed: {s}\n", .{text[0..len]});
        return error.ScriptFailed;
    }
}
