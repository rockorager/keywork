//! Lua D-Bus integration for keywork.dbus.

const std = @import("std");
const SystemdEvent = @import("keywork-runtime").SystemdEvent;
const lua_coro = @import("coro.zig");
const lua_handle = @import("handle.zig");
const lua_task = @import("task.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");
const systemd = @import("systemd_c");

const linux = std.os.linux;
const invalid_fd: i32 = -1;
const unix_fd_type: [*:0]const u8 = "keywork.dbus.unix_fd";

var dbus_temp_z_slot: usize = 0;
var dbus_temp_z_buffers: [8][4096]u8 = undefined;

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allocator: *const fn (*anyopaque) std.mem.Allocator,
        luaState: *const fn (*anyopaque) *c.lua_State,
        systemdEvent: *const fn (*anyopaque) anyerror!*SystemdEvent,
        addBus: *const fn (*anyopaque, Kind) anyerror!*Bus,
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
    fn addBus(self: Host, kind: Kind) !*Bus {
        return self.vtable.addBus(self.ptr, kind);
    }
};

pub const Kind = enum {
    session,
    system,
};

fn hostFromLua(lua_state: *c.lua_State) Host {
    return lua_value.upvaluePointer(*Host, lua_state, 1).*;
}

pub fn pushModule(lua_state: *c.lua_State, host: *Host) void {
    c.lua_createtable(lua_state, 0, 16);
    const dbus_table = c.lua_gettop(lua_state);
    c.lua_pushlightuserdata(lua_state, host);
    lua_value.setClosureField(lua_state, dbus_table, "session", luaDbusSession, 1);
    c.lua_pushlightuserdata(lua_state, host);
    lua_value.setClosureField(lua_state, dbus_table, "system", luaDbusSystem, 1);
    lua_value.setClosureField(lua_state, dbus_table, "string", luaDbusString, 0);
    lua_value.setClosureField(lua_state, dbus_table, "object_path", luaDbusObjectPath, 0);
    lua_value.setClosureField(lua_state, dbus_table, "boolean", luaDbusBoolean, 0);
    lua_value.setClosureField(lua_state, dbus_table, "int32", luaDbusInt32, 0);
    lua_value.setClosureField(lua_state, dbus_table, "uint32", luaDbusUint32, 0);
    lua_value.setClosureField(lua_state, dbus_table, "double", luaDbusDouble, 0);
    lua_value.setClosureField(lua_state, dbus_table, "array", luaDbusArray, 0);
    lua_value.setClosureField(lua_state, dbus_table, "variant", luaDbusVariant, 0);

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

fn checkDbus(result: c_int) !void {
    if (result < 0) return error.DBusOperationFailed;
}

const Subscription = struct {
    bus: *Bus,
    stream: lua_coro.Stream = .{},
    handle_ref: c_int = -1,
    match_rule: ?[:0]const u8 = null,
    slot: ?*systemd.sd_bus_slot = null,
    sender: ?[]const u8 = null,
    path: ?[]const u8 = null,
    path_namespace: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    canceled: bool = false,

    pub fn cancel(self: *Subscription, lua_state: *c.lua_State, mode: lua_coro.CancelMode) void {
        if (self.canceled) return;
        self.canceled = true;
        if (self.slot) |slot| _ = systemd.sd_bus_slot_unref(slot);
        self.slot = null;
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
};

const OwnedName = struct {
    bus: *Bus,
    name: [:0]const u8,
    handle_ref: c_int = -1,
    released: bool = false,

    fn release(self: *OwnedName) void {
        if (self.released) return;
        self.released = true;
        if (!self.bus.closed) _ = systemd.sd_bus_release_name(self.bus.connection, self.name.ptr);
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
    message: *systemd.sd_bus_message,
    handle_ref: c_int = -1,

    /// Drops the handle and message without sending anything.
    fn destroy(self: *PendingReply, allocator: std.mem.Allocator, lua_state: *c.lua_State) void {
        lua_handle.invalidate(lua_state, self.handle_ref);
        self.handle_ref = -1;
        _ = systemd.sd_bus_message_unref(self.message);
        allocator.destroy(self);
    }
};

const Call = struct {
    bus: *Bus,
    /// Registry ref of the coroutine parked on this call, or -1 while the
    /// call is still being armed.
    ref: c_int = -1,
    slot: ?*systemd.sd_bus_slot = null,
    completed: bool = false,

    /// Resumes the parked caller with the reply table, or nil and an error
    /// name. Destroying an uncompleted call (bus close, teardown) never
    /// resumes: the await simply never returns and the coroutine becomes
    /// collectible once the ref is dropped.
    fn complete(self: *Call, message: ?*systemd.sd_bus_message) void {
        if (self.completed) return;
        self.completed = true;
        if (self.ref < 0) return;

        const lua_state = self.bus.host.luaState();
        c.lua_rawgeti(lua_state, c.LUA_REGISTRYINDEX, self.ref);
        const thread = c.lua_tothread(lua_state, -1).?;
        pop(lua_state, 1);

        if (message) |reply| {
            const dbus_error = systemd.sd_bus_message_get_error(reply);
            if (dbus_error != null) {
                c.lua_pushnil(thread);
                pushOptionalDbusString(thread, dbus_error[0].name);
                lua_coro.resumeThread(thread, 2);
            } else {
                pushDbusReply(thread, reply);
                lua_coro.resumeThread(thread, 1);
            }
        } else {
            c.lua_pushnil(thread);
            c.lua_pushliteral(thread, "dbus call failed");
            lua_coro.resumeThread(thread, 2);
        }
    }

    fn deinit(self: *Call, lua_state: *c.lua_State) void {
        if (self.slot) |slot| _ = systemd.sd_bus_slot_unref(slot);
        self.slot = null;
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
    connection: *systemd.sd_bus,
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
    filter_slot: ?*systemd.sd_bus_slot = null,

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
        var connection: ?*systemd.sd_bus = null;
        const result = switch (kind) {
            .session => systemd.sd_bus_open_user(&connection),
            .system => systemd.sd_bus_open_system(&connection),
        };
        try checkDbus(result);
        errdefer _ = systemd.sd_bus_flush_close_unref(connection);
        try checkDbus(systemd.sd_bus_set_exit_on_disconnect(connection, 0));
        const self: Bus = .{
            .host = host,
            .kind = kind,
            .connection = connection.?,
        };
        return self;
    }

    fn installFilter(self: *Bus) !void {
        if (self.filter_slot != null) return;
        try checkDbus(systemd.sd_bus_add_filter(self.connection, &self.filter_slot, dbusFilter, self));
    }

    pub fn register(self: *Bus) !void {
        if (self.registered or self.closed) return;
        const bridge = try self.host.systemdEvent();
        try checkDbus(systemd.sd_bus_attach_event(self.connection, bridge.sdEvent(), 0));
        self.registered = true;
    }

    pub fn unregister(self: *Bus) void {
        if (self.registered) _ = systemd.sd_bus_detach_event(self.connection);
        self.registered = false;
    }

    pub fn close(self: *Bus) void {
        if (self.closed) return;
        self.unregister();
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

        if (self.filter_slot) |slot| _ = systemd.sd_bus_slot_unref(slot);
        self.filter_slot = null;
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

        self.finishClose();
    }

    fn finishClose(self: *Bus) void {
        _ = systemd.sd_bus_flush_close_unref(self.connection);
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
        try checkDbus(systemd.sd_bus_add_match(
            self.connection,
            &subscription.slot,
            subscription.match_rule.?.ptr,
            dbusSubscriptionCallback,
            subscription,
        ));

        try self.subscriptions.append(self.host.allocator(), subscription);
        return subscription;
    }

    fn requestName(self: *Bus, lua_state: *c.lua_State, options_index: c_int) !*OwnedName {
        const name = try stringFromStack(lua_state, options_index);
        var flags: u64 = systemd.SD_BUS_NAME_QUEUE;
        if (c.lua_type(lua_state, options_index + 1) == c.LUA_TTABLE) {
            if (boolField(lua_state, options_index + 1, "allow_replacement")) flags |= systemd.SD_BUS_NAME_ALLOW_REPLACEMENT;
            if (boolField(lua_state, options_index + 1, "replace_existing")) flags |= systemd.SD_BUS_NAME_REPLACE_EXISTING;
            if (boolField(lua_state, options_index + 1, "do_not_queue")) flags &= ~@as(u64, systemd.SD_BUS_NAME_QUEUE);
        }
        const result = systemd.sd_bus_request_name(self.connection, tryZTemp(name).ptr, flags);
        if (result <= 0) return error.DBusNameUnavailable;

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
        if (!self.closed) _ = systemd.sd_bus_release_name(self.connection, tryZTemp(name).ptr);
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
        var message: ?*systemd.sd_bus_message = null;
        try checkDbus(systemd.sd_bus_message_new_method_call(self.connection, &message, destination.ptr, path.ptr, interface.ptr, member.ptr));
        defer _ = systemd.sd_bus_message_unref(message);
        try appendDbusLuaArgs(lua_state, options_index, message.?);

        const timeout_ms = getIntegerField(lua_state, options_index, "timeout_ms", 1000);
        const call_state = try self.host.allocator().create(Call);
        errdefer self.host.allocator().destroy(call_state);
        call_state.* = .{ .bus = self };
        errdefer call_state.deinit(lua_state);

        try self.pending_calls.append(self.host.allocator(), call_state);
        errdefer _ = self.removePendingCall(call_state);
        const call_result = systemd.sd_bus_call_async(
            self.connection,
            &call_state.slot,
            message,
            dbusCallNotify,
            call_state,
            @as(u64, @intCast(timeout_ms)) * std.time.us_per_ms,
        );
        if (call_result < 0) return error.DBusCallFailed;
        // The ref transfers only once nothing can fail, so the errdefer
        // above and the call's deinit never unref twice.
        call_state.ref = thread_ref;
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

    fn emitSignal(self: *Bus, lua_state: *c.lua_State, options_index: c_int) !void {
        const path = try stringField(lua_state, options_index, "path");
        const interface = try stringField(lua_state, options_index, "interface");
        const member = try stringField(lua_state, options_index, "member");
        var message: ?*systemd.sd_bus_message = null;
        try checkDbus(systemd.sd_bus_message_new_signal(self.connection, &message, path.ptr, interface.ptr, member.ptr));
        defer _ = systemd.sd_bus_message_unref(message);
        try appendDbusLuaArgs(lua_state, options_index, message.?);
        try checkDbus(systemd.sd_bus_send(self.connection, message, null));
    }

    fn handleMethodCall(self: *Bus, message: *systemd.sd_bus_message) !bool {
        const path_z = optionalSystemdString(systemd.sd_bus_message_get_path(message)) orelse return false;
        const object = self.exportedObjectForPath(path_z) orelse return false;
        const interface_z = optionalSystemdString(systemd.sd_bus_message_get_interface(message)) orelse return false;
        const member_z = optionalSystemdString(systemd.sd_bus_message_get_member(message)) orelse return false;
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

    fn callExportedMethod(self: *Bus, object: *ExportedObject, message: *systemd.sd_bus_message, interface: []const u8, member: []const u8) !bool {
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
        pending.* = .{ .bus = self, .message = systemd.sd_bus_message_ref(message).? };
        self.pending_replies.append(allocator, pending) catch |err| {
            _ = systemd.sd_bus_message_unref(pending.message);
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

    fn handlePropertiesMethod(self: *Bus, object: *ExportedObject, message: *systemd.sd_bus_message, member: []const u8) !void {
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

    fn replyValues(self: *Bus, message: *systemd.sd_bus_message, lua_state: *c.lua_State, first_index: c_int, count: usize) !void {
        var reply: ?*systemd.sd_bus_message = null;
        try checkDbus(systemd.sd_bus_message_new_method_return(message, &reply));
        defer _ = systemd.sd_bus_message_unref(reply);
        var offset: usize = 0;
        while (offset < count) : (offset += 1) {
            const index = first_index + @as(c_int, @intCast(offset));
            if (c.lua_isnil(lua_state, index)) continue;
            try appendLuaValueToDbusIter(lua_state, index, reply.?);
        }
        try checkDbus(systemd.sd_bus_send(self.connection, reply, null));
    }

    fn replyString(self: *Bus, message: *systemd.sd_bus_message, value: []const u8) !void {
        var reply: ?*systemd.sd_bus_message = null;
        try checkDbus(systemd.sd_bus_message_new_method_return(message, &reply));
        defer _ = systemd.sd_bus_message_unref(reply);
        const value_z = try self.host.allocator().dupeZ(u8, value);
        defer self.host.allocator().free(value_z);
        try appendDbusBasic(reply.?, systemd.SD_BUS_TYPE_STRING, value_z.ptr);
        try checkDbus(systemd.sd_bus_send(self.connection, reply, null));
    }

    fn replyError(self: *Bus, message: *systemd.sd_bus_message, name: []const u8, text: []const u8) !void {
        const allocator = self.host.allocator();
        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);
        const text_z = try allocator.dupeZ(u8, text);
        defer allocator.free(text_z);
        var error_message: ?*systemd.sd_bus_message = null;
        var dbus_error: systemd.sd_bus_error = .{
            .name = name_z.ptr,
            .message = text_z.ptr,
            ._need_free = 0,
        };
        try checkDbus(systemd.sd_bus_message_new_method_error(message, &error_message, &dbus_error));
        defer _ = systemd.sd_bus_message_unref(error_message);
        try checkDbus(systemd.sd_bus_send(self.connection, error_message, null));
    }

    fn replyPropertyGet(self: *Bus, object: *ExportedObject, message: *systemd.sd_bus_message, interface: []const u8, property: []const u8) !void {
        const lua_state = self.host.luaState();
        const original_top = c.lua_gettop(lua_state);
        defer c.lua_settop(lua_state, original_top);
        try pushPropertyGetterResult(lua_state, object, interface, property);
        const signature = try propertySignature(lua_state, object, interface, property);

        var reply: ?*systemd.sd_bus_message = null;
        try checkDbus(systemd.sd_bus_message_new_method_return(message, &reply));
        defer _ = systemd.sd_bus_message_unref(reply);
        try openDbusContainer(reply.?, systemd.SD_BUS_TYPE_VARIANT, signature);
        try appendLuaValueWithSignature(lua_state, -1, signature, reply.?);
        try closeDbusContainer(reply.?);
        try checkDbus(systemd.sd_bus_send(self.connection, reply, null));
    }

    /// Handles org.freedesktop.DBus.Properties.Set: unwraps the variant
    /// into a Lua value, invokes the exported property's `set` function,
    /// and replies with an empty method return. Properties without a `set`
    /// function are read-only.
    fn replyPropertySet(self: *Bus, object: *ExportedObject, message: *systemd.sd_bus_message, interface: []const u8, property: []const u8) !void {
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

    fn replyPropertiesGetAll(self: *Bus, object: *ExportedObject, message: *systemd.sd_bus_message, interface: []const u8) !void {
        const lua_state = self.host.luaState();
        const original_top = c.lua_gettop(lua_state);
        defer c.lua_settop(lua_state, original_top);

        var reply: ?*systemd.sd_bus_message = null;
        try checkDbus(systemd.sd_bus_message_new_method_return(message, &reply));
        defer _ = systemd.sd_bus_message_unref(reply);
        try openDbusContainer(reply.?, systemd.SD_BUS_TYPE_ARRAY, "{sv}");

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
                    try appendPropertyDictEntry(lua_state, reply.?, property_name, signature, -1);
                    pop(lua_state, 2);
                }
            }
        }
        try closeDbusContainer(reply.?);
        try checkDbus(systemd.sd_bus_send(self.connection, reply, null));
    }
};

fn dbusCallNotify(message: ?*systemd.sd_bus_message, user_data: ?*anyopaque, _: [*c]systemd.sd_bus_error) callconv(.c) c_int {
    const call: *Call = @ptrCast(@alignCast(user_data orelse return 0));
    call.complete(message);
    _ = call.bus.removePendingCall(call);
    call.destroy(call.bus.host.allocator(), call.bus.host.luaState());
    return 0;
}

fn dbusSubscriptionCallback(message: ?*systemd.sd_bus_message, user_data: ?*anyopaque, _: [*c]systemd.sd_bus_error) callconv(.c) c_int {
    const subscription: *Subscription = @ptrCast(@alignCast(user_data orelse return 0));
    if (subscription.canceled or subscription.bus.closed) return 0;
    const bus = subscription.bus;
    const lua_state = bus.host.luaState();
    pushDbusSignal(lua_state, message orelse return 0);
    subscription.stream.deliver(bus.host.allocator(), lua_state) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus signal dispatch failed: {}", .{err});
    };
    return 0;
}

fn dbusFilter(message: ?*systemd.sd_bus_message, user_data: ?*anyopaque, _: [*c]systemd.sd_bus_error) callconv(.c) c_int {
    const bus: *Bus = @ptrCast(@alignCast(user_data orelse return 0));
    if (bus.closed) return 0;
    const msg = message orelse return 0;
    var message_type: u8 = 0;
    if (systemd.sd_bus_message_get_type(msg, &message_type) < 0 or message_type != systemd.SD_BUS_MESSAGE_METHOD_CALL) return 0;
    const handled = bus.handleMethodCall(msg) catch |err| blk: {
        std.log.scoped(.keywork_luajit).warn("dbus method dispatch failed: {}", .{err});
        break :blk true;
    };
    return if (handled) 1 else 0;
}

fn luaDbusString(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "string", 1, null);
}

fn luaDbusObjectPath(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "object_path", 1, null);
}

fn luaDbusBoolean(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "boolean", 1, null);
}

fn luaDbusInt32(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "int32", 1, null);
}

fn luaDbusUint32(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "uint32", 1, null);
}

fn luaDbusDouble(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    return pushDbusTypedValue(lua_state_optional.?, "double", 1, null);
}

fn luaDbusArray(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.luaL_checktype(lua_state, 1, c.LUA_TSTRING);
    c.luaL_checktype(lua_state, 2, c.LUA_TTABLE);
    return pushDbusTypedValue(lua_state, "array", 2, 1);
}

fn luaDbusVariant(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.luaL_checktype(lua_state, 1, c.LUA_TSTRING);
    return pushDbusTypedValue(lua_state, "variant", 2, 1);
}

fn pushDbusTypedValue(lua_state: *c.lua_State, comptime type_name: [:0]const u8, value_index: c_int, signature_index: ?c_int) c_int {
    c.lua_createtable(lua_state, 0, if (signature_index == null) 2 else 3);
    lua_value.setStringField(lua_state, -1, "__dbus_type", type_name);
    if (signature_index) |index| {
        c.lua_pushvalue(lua_state, index);
        c.lua_setfield(lua_state, -2, "signature");
    }
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
            return lua_value.pushNilError(lua_state, err);
        };
        setSharedBus(lua_state, kind, created);
        break :blk created;
    };

    const allocator = host.allocator();
    const lease = allocator.create(BusLease) catch |err| {
        return lua_value.pushNilError(lua_state, err);
    };
    lease.* = .{ .bus = bus };
    bus.leases.append(allocator, lease) catch |err| {
        allocator.destroy(lease);
        return lua_value.pushNilError(lua_state, err);
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
    // An awaited call needs a distinguishable result, so a dead bus handle
    // reports nil, err instead of the usual silent no-op.
    const bus = leasedBus(lua_state, 1) orelse return lua_value.pushNilMessage(lua_state, "BusClosed");
    c.luaL_checktype(lua_state, 2, c.LUA_TTABLE);
    if (lua_coro.onMainThread(lua_state)) return c.luaL_error(lua_state, "bus:call must be called from a coroutine (wrap the caller in loop.spawn)");
    // Sending on a disconnected bus is an expected runtime condition and
    // reports nil, err; bad options and allocation failures still raise.
    // Method-call errors from the peer resume the caller as nil, error_name.
    const ref = lua_coro.refCurrentThread(lua_state);
    bus.call(lua_state, 2, ref) catch |err| {
        std.log.scoped(.keywork_luajit).warn("dbus call failed: {}", .{err});
        if (err != error.DBusCallFailed) return c.luaL_error(lua_state, "dbus call failed");
        return lua_value.pushNilError(lua_state, err);
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
        return lua_value.pushNilError(lua_state, err);
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
    var name: [*c]const u8 = null;
    if (systemd.sd_bus_get_unique_name(bus.connection, &name) < 0 or name == null) {
        c.lua_pushnil(lua_state);
        c.lua_pushlstring(lua_state, "no unique name", "no unique name".len);
        return 2;
    }
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

fn appendDbusLuaArgs(lua_state: *c.lua_State, options_index: c_int, message: *systemd.sd_bus_message) !void {
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
        try appendLuaValueToDbusIter(lua_state, -1, message);
        pop(lua_state, 1);
    }
}

fn appendLuaValueToDbusIter(lua_state: *c.lua_State, index: c_int, message: *systemd.sd_bus_message) anyerror!void {
    const absolute = absoluteIndex(lua_state, index);
    if (c.lua_type(lua_state, absolute) == c.LUA_TTABLE) {
        c.lua_getfield(lua_state, absolute, "__dbus_type");
        defer pop(lua_state, 1);
        if (!c.lua_isnil(lua_state, -1)) {
            const type_name = try stringFromStack(lua_state, -1);
            if (std.mem.eql(u8, type_name, "string")) return appendTypedField(lua_state, absolute, "s", message);
            if (std.mem.eql(u8, type_name, "object_path")) return appendTypedField(lua_state, absolute, "o", message);
            if (std.mem.eql(u8, type_name, "boolean")) return appendTypedField(lua_state, absolute, "b", message);
            if (std.mem.eql(u8, type_name, "int32")) return appendTypedField(lua_state, absolute, "i", message);
            if (std.mem.eql(u8, type_name, "uint32")) return appendTypedField(lua_state, absolute, "u", message);
            if (std.mem.eql(u8, type_name, "double")) return appendTypedField(lua_state, absolute, "d", message);
            if (std.mem.eql(u8, type_name, "array")) return appendTypedArray(lua_state, absolute, message);
            if (std.mem.eql(u8, type_name, "variant")) return appendTypedVariant(lua_state, absolute, message);
            return error.UnsupportedDbusArgument;
        }
    }
    switch (c.lua_type(lua_state, absolute)) {
        c.LUA_TSTRING => try appendLuaValueWithSignature(lua_state, absolute, "s", message),
        c.LUA_TBOOLEAN => try appendLuaValueWithSignature(lua_state, absolute, "b", message),
        c.LUA_TNUMBER => try appendLuaValueWithSignature(lua_state, absolute, "d", message),
        else => return error.UnsupportedDbusArgument,
    }
}

fn appendTypedField(lua_state: *c.lua_State, table: c_int, signature: []const u8, message: *systemd.sd_bus_message) !void {
    c.lua_getfield(lua_state, table, "value");
    defer pop(lua_state, 1);
    try appendLuaValueWithSignature(lua_state, -1, signature, message);
}

fn appendTypedArray(lua_state: *c.lua_State, table: c_int, message: *systemd.sd_bus_message) !void {
    c.lua_getfield(lua_state, table, "signature");
    const signature = try stringFromStack(lua_state, -1);
    defer pop(lua_state, 1);
    c.lua_getfield(lua_state, table, "value");
    defer pop(lua_state, 1);
    try appendArrayWithSignature(lua_state, -1, signature, message);
}

fn appendTypedVariant(lua_state: *c.lua_State, table: c_int, message: *systemd.sd_bus_message) !void {
    c.lua_getfield(lua_state, table, "signature");
    const signature = try stringFromStack(lua_state, -1);
    defer pop(lua_state, 1);
    c.lua_getfield(lua_state, table, "value");
    defer pop(lua_state, 1);
    try openDbusContainer(message, systemd.SD_BUS_TYPE_VARIANT, signature);
    try appendLuaValueWithSignature(lua_state, -1, signature, message);
    try closeDbusContainer(message);
}

fn appendLuaValueWithSignature(lua_state: *c.lua_State, index: c_int, signature: []const u8, message: *systemd.sd_bus_message) anyerror!void {
    if (signature.len == 0) return;
    const absolute = absoluteIndex(lua_state, index);
    if (c.lua_type(lua_state, absolute) == c.LUA_TTABLE) {
        c.lua_getfield(lua_state, absolute, "__dbus_type");
        if (!c.lua_isnil(lua_state, -1)) {
            const type_name = try stringFromStack(lua_state, -1);
            pop(lua_state, 1);
            if (std.mem.eql(u8, type_name, "array") or std.mem.eql(u8, type_name, "variant")) return appendLuaValueToDbusIter(lua_state, absolute, message);
            c.lua_getfield(lua_state, absolute, "value");
            defer pop(lua_state, 1);
            return appendLuaValueWithSignature(lua_state, -1, signature, message);
        }
        pop(lua_state, 1);
    }
    if (signature[0] == 'a') return appendArrayWithSignature(lua_state, index, signature[1..], message);
    if (signature[0] == '(') return appendStructWithSignature(lua_state, index, signature, message);
    switch (signature[0]) {
        's' => {
            const value = tryZTemp(try stringFromStack(lua_state, index));
            try appendDbusBasic(message, systemd.SD_BUS_TYPE_STRING, value.ptr);
        },
        'o' => {
            const value = tryZTemp(try stringFromStack(lua_state, index));
            try appendDbusBasic(message, systemd.SD_BUS_TYPE_OBJECT_PATH, value.ptr);
        },
        'b' => {
            var value: c_int = if (c.lua_toboolean(lua_state, index) != 0) 1 else 0;
            try appendDbusBasic(message, systemd.SD_BUS_TYPE_BOOLEAN, &value);
        },
        'i' => {
            var value: i32 = @intCast(c.lua_tointeger(lua_state, index));
            try appendDbusBasic(message, systemd.SD_BUS_TYPE_INT32, &value);
        },
        'u' => {
            var value: u32 = @intCast(c.lua_tointeger(lua_state, index));
            try appendDbusBasic(message, systemd.SD_BUS_TYPE_UINT32, &value);
        },
        'y' => {
            var value: u8 = @intCast(c.lua_tointeger(lua_state, index));
            try appendDbusBasic(message, systemd.SD_BUS_TYPE_BYTE, &value);
        },
        'n' => {
            var value: i16 = @intCast(c.lua_tointeger(lua_state, index));
            try appendDbusBasic(message, systemd.SD_BUS_TYPE_INT16, &value);
        },
        'q' => {
            var value: u16 = @intCast(c.lua_tointeger(lua_state, index));
            try appendDbusBasic(message, systemd.SD_BUS_TYPE_UINT16, &value);
        },
        'd' => {
            var value: f64 = c.lua_tonumber(lua_state, index);
            try appendDbusBasic(message, systemd.SD_BUS_TYPE_DOUBLE, &value);
        },
        'v' => try appendLuaValueToDbusIter(lua_state, index, message),
        else => return error.UnsupportedDbusArgument,
    }
}

fn appendArrayWithSignature(lua_state: *c.lua_State, index: c_int, element_signature: []const u8, message: *systemd.sd_bus_message) !void {
    try expectType(lua_state, index, c.LUA_TTABLE);
    try openDbusContainer(message, systemd.SD_BUS_TYPE_ARRAY, element_signature);
    const table = absoluteIndex(lua_state, index);
    if (element_signature.len > 0 and element_signature[0] == '{') {
        try appendDictEntries(lua_state, table, element_signature, message);
    } else {
        var item_index: c_int = 1;
        while (true) : (item_index += 1) {
            c.lua_rawgeti(lua_state, table, item_index);
            if (c.lua_isnil(lua_state, -1)) {
                pop(lua_state, 1);
                break;
            }
            try appendLuaValueWithSignature(lua_state, -1, element_signature, message);
            pop(lua_state, 1);
        }
    }
    try closeDbusContainer(message);
}

/// Appends a Lua map as D-Bus dict entries. `element_signature` is the
/// full entry signature including braces (e.g. `{sv}`).
fn appendDictEntries(lua_state: *c.lua_State, table: c_int, element_signature: []const u8, message: *systemd.sd_bus_message) !void {
    if (element_signature.len < 4 or element_signature[element_signature.len - 1] != '}') return error.InvalidDbusSignature;
    const inner = element_signature[1 .. element_signature.len - 1];
    const key_length = try signatureElementLength(inner);
    const key_signature = inner[0..key_length];
    const value_signature = inner[key_length..];
    if (value_signature.len != try signatureElementLength(value_signature)) return error.InvalidDbusSignature;

    c.lua_pushnil(lua_state);
    while (c.lua_next(lua_state, table) != 0) {
        try openDbusContainer(message, systemd.SD_BUS_TYPE_DICT_ENTRY, inner);
        // Append a copy of the key: serializing may lua_tolstring it,
        // and converting the original in place would corrupt lua_next.
        c.lua_pushvalue(lua_state, -2);
        try appendLuaValueWithSignature(lua_state, -1, key_signature, message);
        pop(lua_state, 1);
        try appendLuaValueWithSignature(lua_state, -1, value_signature, message);
        try closeDbusContainer(message);
        pop(lua_state, 1);
    }
}

/// Appends a positional Lua sequence as a D-Bus struct. `signature`
/// includes the surrounding parentheses (e.g. `(sa(us))`).
fn appendStructWithSignature(lua_state: *c.lua_State, index: c_int, signature: []const u8, message: *systemd.sd_bus_message) !void {
    if (signature.len < 3 or signature[signature.len - 1] != ')') return error.InvalidDbusSignature;
    try expectType(lua_state, index, c.LUA_TTABLE);
    const table = absoluteIndex(lua_state, index);
    const fields = signature[1 .. signature.len - 1];
    try openDbusContainer(message, systemd.SD_BUS_TYPE_STRUCT, fields);
    var offset: usize = 0;
    var item_index: c_int = 1;
    while (offset < fields.len) : (item_index += 1) {
        const field_length = try signatureElementLength(fields[offset..]);
        c.lua_rawgeti(lua_state, table, item_index);
        defer pop(lua_state, 1);
        try appendLuaValueWithSignature(lua_state, -1, fields[offset..][0..field_length], message);
        offset += field_length;
    }
    try closeDbusContainer(message);
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

fn appendPropertyDictEntry(lua_state: *c.lua_State, message: *systemd.sd_bus_message, name: []const u8, signature: []const u8, value_index: c_int) !void {
    try openDbusContainer(message, systemd.SD_BUS_TYPE_DICT_ENTRY, "sv");
    try appendDbusBasic(message, systemd.SD_BUS_TYPE_STRING, tryZTemp(name).ptr);
    try openDbusContainer(message, systemd.SD_BUS_TYPE_VARIANT, signature);
    try appendLuaValueWithSignature(lua_state, value_index, signature, message);
    try closeDbusContainer(message);
    try closeDbusContainer(message);
}

fn appendDbusBasic(message: *systemd.sd_bus_message, type_: c_int, value: anytype) !void {
    const opaque_value: *const anyopaque = @ptrCast(value);
    try checkDbus(systemd.sd_bus_message_append_basic(message, @intCast(type_), opaque_value));
}

fn openDbusContainer(message: *systemd.sd_bus_message, type_: c_int, contents: []const u8) !void {
    try checkDbus(systemd.sd_bus_message_open_container(message, @intCast(type_), tryZTemp(contents).ptr));
}

fn closeDbusContainer(message: *systemd.sd_bus_message) !void {
    try checkDbus(systemd.sd_bus_message_close_container(message));
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

fn pushDbusSignal(lua_state: *c.lua_State, message: *systemd.sd_bus_message) void {
    c.lua_createtable(lua_state, 0, 6);
    const table = c.lua_gettop(lua_state);
    pushOptionalDbusString(lua_state, systemd.sd_bus_message_get_sender(message));
    c.lua_setfield(lua_state, table, "sender");
    pushOptionalDbusString(lua_state, systemd.sd_bus_message_get_path(message));
    c.lua_setfield(lua_state, table, "path");
    pushOptionalDbusString(lua_state, systemd.sd_bus_message_get_interface(message));
    c.lua_setfield(lua_state, table, "interface");
    pushOptionalDbusString(lua_state, systemd.sd_bus_message_get_member(message));
    c.lua_setfield(lua_state, table, "member");

    const signature = systemd.sd_bus_message_get_signature(message, 1);
    if (signature != null) {
        c.lua_pushstring(lua_state, signature);
    } else {
        c.lua_pushnil(lua_state);
    }
    c.lua_setfield(lua_state, table, "signature");

    pushDbusArgsTable(lua_state, message);
    c.lua_setfield(lua_state, table, "args");
}

fn pushDbusReply(lua_state: *c.lua_State, message: *systemd.sd_bus_message) void {
    c.lua_createtable(lua_state, 0, 2);
    const table = c.lua_gettop(lua_state);
    const signature = systemd.sd_bus_message_get_signature(message, 1);
    if (signature != null) {
        c.lua_pushstring(lua_state, signature);
    } else {
        c.lua_pushnil(lua_state);
    }
    c.lua_setfield(lua_state, table, "signature");

    pushDbusArgsTable(lua_state, message);
    c.lua_setfield(lua_state, table, "args");
}

fn pushCallTable(lua_state: *c.lua_State, message: *systemd.sd_bus_message) void {
    c.lua_createtable(lua_state, 0, 6);
    const table = c.lua_gettop(lua_state);
    pushOptionalDbusString(lua_state, systemd.sd_bus_message_get_sender(message));
    c.lua_setfield(lua_state, table, "sender");
    pushOptionalDbusString(lua_state, systemd.sd_bus_message_get_path(message));
    c.lua_setfield(lua_state, table, "path");
    pushOptionalDbusString(lua_state, systemd.sd_bus_message_get_interface(message));
    c.lua_setfield(lua_state, table, "interface");
    pushOptionalDbusString(lua_state, systemd.sd_bus_message_get_member(message));
    c.lua_setfield(lua_state, table, "member");
    var serial: u64 = 0;
    _ = systemd.sd_bus_message_get_cookie(message, &serial);
    lua_value.setNumberField(lua_state, table, "serial", @floatFromInt(serial));
}

fn pushDbusMessageArgs(lua_state: *c.lua_State, message: *systemd.sd_bus_message) usize {
    var count: usize = 0;
    _ = systemd.sd_bus_message_rewind(message, 1);
    while (systemd.sd_bus_message_at_end(message, 1) == 0) {
        pushDbusIterValue(lua_state, message);
        count += 1;
    }
    return count;
}

fn methodCallStringPair(message: *systemd.sd_bus_message) ?struct { interface: []const u8, property: []const u8 } {
    const interface = methodCallString(message, 0) orelse return null;
    const property = methodCallString(message, 1) orelse return null;
    return .{ .interface = interface, .property = property };
}

fn methodCallString(message: *systemd.sd_bus_message, wanted_index: usize) ?[]const u8 {
    _ = systemd.sd_bus_message_rewind(message, 1);
    var index: usize = 0;
    while (systemd.sd_bus_message_at_end(message, 1) == 0) : (index += 1) {
        if (index == wanted_index) {
            var value: [*c]const u8 = null;
            if (systemd.sd_bus_message_read_basic(message, systemd.SD_BUS_TYPE_STRING, @ptrCast(&value)) <= 0) return null;
            return std.mem.span(value);
        }
        if (skipDbusValue(message) <= 0) break;
    }
    return null;
}

/// Pushes method-call argument `wanted_index` (0-based) as a Lua value, or
/// returns false when the message has too few arguments. Variants decode
/// transparently like all other incoming values.
fn pushMethodCallArg(lua_state: *c.lua_State, message: *systemd.sd_bus_message, wanted_index: usize) bool {
    _ = systemd.sd_bus_message_rewind(message, 1);
    var index: usize = 0;
    while (index < wanted_index) : (index += 1) {
        if (skipDbusValue(message) <= 0) return false;
    }
    if (systemd.sd_bus_message_at_end(message, 1) != 0) return false;
    pushDbusIterValue(lua_state, message);
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

fn pushDbusArgsTable(lua_state: *c.lua_State, message: *systemd.sd_bus_message) void {
    c.lua_createtable(lua_state, 0, 0);
    const args_table = c.lua_gettop(lua_state);
    _ = systemd.sd_bus_message_rewind(message, 1);
    var arg_index: c_int = 1;
    while (systemd.sd_bus_message_at_end(message, 1) == 0) : (arg_index += 1) {
        pushDbusIterValue(lua_state, message);
        c.lua_rawseti(lua_state, args_table, arg_index);
    }
}

fn optionalSystemdString(value: [*c]const u8) ?[*:0]const u8 {
    if (value == null) return null;
    return @ptrCast(value);
}

fn pushOptionalDbusString(lua_state: *c.lua_State, value: [*c]const u8) void {
    if (optionalSystemdString(value)) |string| {
        c.lua_pushstring(lua_state, string);
    } else {
        c.lua_pushnil(lua_state);
    }
}

fn unixFd(lua_state: *c.lua_State, index: c_int) *i32 {
    return @ptrCast(@alignCast(c.luaL_checkudata(lua_state, index, unix_fd_type).?));
}

fn closeUnixFd(fd: *i32) void {
    if (fd.* == invalid_fd) return;
    _ = linux.close(fd.*);
    fd.* = invalid_fd;
}

fn luaUnixFdClose(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    closeUnixFd(unixFd(lua_state_optional.?, 1));
    return 0;
}

fn luaUnixFdClosed(lua_state_optional: ?*c.lua_State) callconv(.c) c_int {
    const lua_state = lua_state_optional.?;
    c.lua_pushboolean(lua_state, if (unixFd(lua_state, 1).* == invalid_fd) 1 else 0);
    return 1;
}

fn ensureUnixFdMetatable(lua_state: *c.lua_State) void {
    if (c.luaL_newmetatable(lua_state, unix_fd_type) != 0) {
        c.lua_pushcclosure(lua_state, luaUnixFdClose, 0);
        c.lua_setfield(lua_state, -2, "__gc");
        c.lua_createtable(lua_state, 0, 2);
        lua_value.setClosureField(lua_state, -1, "close", luaUnixFdClose, 0);
        lua_value.setClosureField(lua_state, -1, "closed", luaUnixFdClosed, 0);
        c.lua_setfield(lua_state, -2, "__index");
    }
}

fn pushUnixFd(lua_state: *c.lua_State, value: i32) void {
    const fd: *i32 = @ptrCast(@alignCast(c.lua_newuserdata(lua_state, @sizeOf(i32)).?));
    fd.* = value;
    ensureUnixFdMetatable(lua_state);
    _ = c.lua_setmetatable(lua_state, -2);
}

fn pushDbusIterValue(lua_state: *c.lua_State, message: *systemd.sd_bus_message) void {
    var type_: u8 = 0;
    var contents: [*c]const u8 = null;
    if (systemd.sd_bus_message_peek_type(message, &type_, &contents) <= 0) {
        c.lua_pushnil(lua_state);
        return;
    }
    switch (type_) {
        systemd.SD_BUS_TYPE_STRING, systemd.SD_BUS_TYPE_OBJECT_PATH, systemd.SD_BUS_TYPE_SIGNATURE => {
            var value: [*c]const u8 = null;
            if (systemd.sd_bus_message_read_basic(message, type_, @ptrCast(&value)) <= 0 or value == null) return c.lua_pushnil(lua_state);
            c.lua_pushstring(lua_state, value);
        },
        systemd.SD_BUS_TYPE_BOOLEAN => {
            var value: c_int = 0;
            if (systemd.sd_bus_message_read_basic(message, type_, @ptrCast(&value)) <= 0) return c.lua_pushnil(lua_state);
            c.lua_pushboolean(lua_state, if (value != 0) 1 else 0);
        },
        systemd.SD_BUS_TYPE_BYTE => {
            var value: u8 = 0;
            if (systemd.sd_bus_message_read_basic(message, type_, @ptrCast(&value)) <= 0) return c.lua_pushnil(lua_state);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        systemd.SD_BUS_TYPE_INT16 => {
            var value: i16 = 0;
            if (systemd.sd_bus_message_read_basic(message, type_, @ptrCast(&value)) <= 0) return c.lua_pushnil(lua_state);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        systemd.SD_BUS_TYPE_UINT16 => {
            var value: u16 = 0;
            if (systemd.sd_bus_message_read_basic(message, type_, @ptrCast(&value)) <= 0) return c.lua_pushnil(lua_state);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        systemd.SD_BUS_TYPE_INT32 => {
            var value: i32 = 0;
            if (systemd.sd_bus_message_read_basic(message, type_, @ptrCast(&value)) <= 0) return c.lua_pushnil(lua_state);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        systemd.SD_BUS_TYPE_UINT32 => {
            var value: u32 = 0;
            if (systemd.sd_bus_message_read_basic(message, type_, @ptrCast(&value)) <= 0) return c.lua_pushnil(lua_state);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        systemd.SD_BUS_TYPE_INT64 => {
            var value: i64 = 0;
            if (systemd.sd_bus_message_read_basic(message, type_, @ptrCast(&value)) <= 0) return c.lua_pushnil(lua_state);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        systemd.SD_BUS_TYPE_UINT64 => {
            var value: u64 = 0;
            if (systemd.sd_bus_message_read_basic(message, type_, @ptrCast(&value)) <= 0) return c.lua_pushnil(lua_state);
            c.lua_pushnumber(lua_state, @floatFromInt(value));
        },
        systemd.SD_BUS_TYPE_DOUBLE => {
            var value: f64 = 0;
            if (systemd.sd_bus_message_read_basic(message, type_, @ptrCast(&value)) <= 0) return c.lua_pushnil(lua_state);
            c.lua_pushnumber(lua_state, value);
        },
        systemd.SD_BUS_TYPE_UNIX_FD => {
            // sd-bus owns the descriptor returned by read_basic. Duplicate
            // it with CLOEXEC before transferring ownership to Lua.
            var value: c_int = invalid_fd;
            if (systemd.sd_bus_message_read_basic(message, type_, @ptrCast(&value)) <= 0 or value < 0) {
                c.lua_pushnil(lua_state);
            } else {
                const duplicate = linux.fcntl(value, linux.F.DUPFD_CLOEXEC, 0);
                if (linux.errno(duplicate) != .SUCCESS) c.lua_pushnil(lua_state) else pushUnixFd(lua_state, @intCast(duplicate));
            }
        },
        systemd.SD_BUS_TYPE_VARIANT => {
            if (systemd.sd_bus_message_enter_container(message, type_, contents) <= 0) return c.lua_pushnil(lua_state);
            pushDbusIterValue(lua_state, message);
            _ = systemd.sd_bus_message_exit_container(message);
        },
        systemd.SD_BUS_TYPE_ARRAY => {
            const element_signature = if (contents == null) "" else std.mem.span(contents);
            if (element_signature.len > 0 and element_signature[0] == '{') {
                pushDbusIterDict(lua_state, message, element_signature);
            } else if (std.mem.eql(u8, element_signature, "y")) {
                pushDbusIterByteArray(lua_state, message);
            } else {
                pushDbusIterSequence(lua_state, message, type_, element_signature);
            }
        },
        systemd.SD_BUS_TYPE_STRUCT, systemd.SD_BUS_TYPE_DICT_ENTRY => pushDbusIterSequence(lua_state, message, type_, if (contents == null) "" else std.mem.span(contents)),
        else => {
            _ = skipDbusValue(message);
            c.lua_pushnil(lua_state);
        },
    }
}

fn pushDbusIterByteArray(lua_state: *c.lua_State, message: *systemd.sd_bus_message) void {
    var bytes: ?*const anyopaque = null;
    var count: usize = 0;
    if (systemd.sd_bus_message_read_array(message, systemd.SD_BUS_TYPE_BYTE, &bytes, &count) <= 0 or count == 0) {
        c.lua_pushliteral(lua_state, "");
    } else {
        c.lua_pushlstring(lua_state, @ptrCast(bytes.?), count);
    }
}

/// Decodes a D-Bus dictionary (an array of dict entries, e.g. `a{sv}`)
/// into a Lua map keyed by the entry keys instead of a positional array
/// of `{key, value}` pairs.
fn pushDbusIterDict(lua_state: *c.lua_State, message: *systemd.sd_bus_message, signature: []const u8) void {
    c.lua_createtable(lua_state, 0, 0);
    const table = c.lua_gettop(lua_state);
    if (systemd.sd_bus_message_enter_container(message, systemd.SD_BUS_TYPE_ARRAY, tryZTemp(signature).ptr) <= 0) return;
    while (systemd.sd_bus_message_at_end(message, 0) == 0) {
        const inner = signature[1 .. signature.len - 1];
        if (systemd.sd_bus_message_enter_container(message, systemd.SD_BUS_TYPE_DICT_ENTRY, tryZTemp(inner).ptr) <= 0) break;
        pushDbusIterValue(lua_state, message);
        // Keys are basic D-Bus types, so nil only appears on malformed
        // input; nil keys are illegal in Lua tables, so drop the entry.
        if (c.lua_isnil(lua_state, -1)) {
            pop(lua_state, 1);
        } else if (systemd.sd_bus_message_at_end(message, 0) == 0) {
            pushDbusIterValue(lua_state, message);
            c.lua_settable(lua_state, table);
        } else {
            pop(lua_state, 1);
        }
        _ = systemd.sd_bus_message_exit_container(message);
    }
    _ = systemd.sd_bus_message_exit_container(message);
}

fn pushDbusIterSequence(lua_state: *c.lua_State, message: *systemd.sd_bus_message, type_: u8, contents: []const u8) void {
    c.lua_createtable(lua_state, 0, 0);
    const table = c.lua_gettop(lua_state);
    if (systemd.sd_bus_message_enter_container(message, type_, tryZTemp(contents).ptr) <= 0) return;
    var index: c_int = 1;
    while (systemd.sd_bus_message_at_end(message, 0) == 0) : (index += 1) {
        pushDbusIterValue(lua_state, message);
        c.lua_rawseti(lua_state, table, index);
    }
    _ = systemd.sd_bus_message_exit_container(message);
}

fn skipDbusValue(message: *systemd.sd_bus_message) c_int {
    var type_: u8 = 0;
    var contents: [*c]const u8 = null;
    if (systemd.sd_bus_message_peek_type(message, &type_, &contents) <= 0) return 0;
    const inner = if (contents == null) "" else std.mem.span(contents);
    var signature_buffer: [4096]u8 = undefined;
    const signature = switch (type_) {
        systemd.SD_BUS_TYPE_ARRAY => std.fmt.bufPrintZ(&signature_buffer, "a{s}", .{inner}) catch return -1,
        systemd.SD_BUS_TYPE_STRUCT => std.fmt.bufPrintZ(&signature_buffer, "({s})", .{inner}) catch return -1,
        systemd.SD_BUS_TYPE_DICT_ENTRY => std.fmt.bufPrintZ(&signature_buffer, "{{{s}}}", .{inner}) catch return -1,
        else => std.fmt.bufPrintZ(&signature_buffer, "{c}", .{type_}) catch return -1,
    };
    return systemd.sd_bus_message_skip(message, signature.ptr);
}

fn tryZTemp(value: []const u8) [:0]const u8 {
    std.debug.assert(value.len < dbus_temp_z_buffers[0].len);
    const slot = dbus_temp_z_slot % dbus_temp_z_buffers.len;
    dbus_temp_z_slot +%= 1;
    @memcpy(dbus_temp_z_buffers[slot][0..value.len], value);
    dbus_temp_z_buffers[slot][value.len] = 0;
    return dbus_temp_z_buffers[slot][0..value.len :0];
}

fn testMessage() !*systemd.sd_bus_message {
    var bus: ?*systemd.sd_bus = null;
    try checkDbus(systemd.sd_bus_open_user(&bus));
    defer _ = systemd.sd_bus_unref(bus);
    var message: ?*systemd.sd_bus_message = null;
    try checkDbus(systemd.sd_bus_message_new_signal(bus, &message, "/test", "test.Interface", "Test"));
    return message.?;
}

fn sealTestMessage(message: *systemd.sd_bus_message) !void {
    try checkDbus(systemd.sd_bus_message_seal(message, 1, 0));
}

fn testAppendVariantString(message: *systemd.sd_bus_message, value: [*:0]const u8) !void {
    try openDbusContainer(message, systemd.SD_BUS_TYPE_VARIANT, "s");
    try appendDbusBasic(message, systemd.SD_BUS_TYPE_STRING, value);
    try closeDbusContainer(message);
}

fn testAppendDictEntryString(message: *systemd.sd_bus_message, key: [*:0]const u8, value: [*:0]const u8) !void {
    try openDbusContainer(message, systemd.SD_BUS_TYPE_DICT_ENTRY, "sv");
    try appendDbusBasic(message, systemd.SD_BUS_TYPE_STRING, key);
    try testAppendVariantString(message, value);
    try closeDbusContainer(message);
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

test "dbus UNIX_FD replies decode to owning Lua userdata" {
    const lua_state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(lua_state);
    c.luaL_openlibs(lua_state);

    const opened = linux.open("/dev/null", .{}, 0);
    if (opened >= 4096) return error.OpenFailed;
    var source_fd: c_int = @intCast(opened);
    defer _ = linux.close(source_fd);

    const message = try testMessage();
    defer _ = systemd.sd_bus_message_unref(message);
    try appendDbusBasic(message, systemd.SD_BUS_TYPE_UNIX_FD, &source_fd);
    try sealTestMessage(message);

    // Decoding creates a third owner. Exercise both methods, including an
    // idempotent close, without exposing the descriptor to Lua.
    pushDbusArgsTable(lua_state, message);
    c.lua_setglobal(lua_state, "args");
    const check_script =
        \\local fd = args[1]
        \\assert(type(fd) == "userdata")
        \\assert(not fd:closed())
        \\fd:close()
        \\assert(fd:closed())
        \\fd:close()
        \\assert(fd:closed())
    ;
    if (c.luaL_loadstring(lua_state, check_script) != 0) return error.LoadFailed;
    if (c.lua_pcall(lua_state, 0, 0, 0) != 0) return error.ScriptFailed;

    // A fresh read is another owned duplicate. Drop its only Lua
    // reference and verify __gc closes it.
    _ = systemd.sd_bus_message_rewind(message, 1);
    pushDbusIterValue(lua_state, message);
    const collected_fd = unixFd(lua_state, -1).*;
    try std.testing.expect(collected_fd >= 0);
    try std.testing.expect(linux.fcntl(collected_fd, linux.F.GETFD, 0) < 4096);
    pop(lua_state, 1);
    _ = c.lua_gc(lua_state, c.LUA_GCCOLLECT, 0);
    _ = c.lua_gc(lua_state, c.LUA_GCCOLLECT, 0);
    try std.testing.expect(linux.fcntl(collected_fd, linux.F.GETFD, 0) >= 4096);
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

    const message = try testMessage();
    defer _ = systemd.sd_bus_message_unref(message);

    c.lua_getglobal(lua_state, "payload");
    try appendDbusLuaArgs(lua_state, absoluteIndex(lua_state, -1), message);
    pop(lua_state, 1);
    try sealTestMessage(message);

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
    const message = try testMessage();
    defer _ = systemd.sd_bus_message_unref(message);

    // arg 1: a{sv} with a string, an int32, and a nested a{sv}.
    {
        try openDbusContainer(message, systemd.SD_BUS_TYPE_ARRAY, "{sv}");
        try testAppendDictEntryString(message, "name", "keywork");
        {
            try openDbusContainer(message, systemd.SD_BUS_TYPE_DICT_ENTRY, "sv");
            try appendDbusBasic(message, systemd.SD_BUS_TYPE_STRING, "count");
            try openDbusContainer(message, systemd.SD_BUS_TYPE_VARIANT, "i");
            var count: i32 = 7;
            try appendDbusBasic(message, systemd.SD_BUS_TYPE_INT32, &count);
            try closeDbusContainer(message);
            try closeDbusContainer(message);
        }
        {
            try openDbusContainer(message, systemd.SD_BUS_TYPE_DICT_ENTRY, "sv");
            try appendDbusBasic(message, systemd.SD_BUS_TYPE_STRING, "nested");
            try openDbusContainer(message, systemd.SD_BUS_TYPE_VARIANT, "a{sv}");
            try openDbusContainer(message, systemd.SD_BUS_TYPE_ARRAY, "{sv}");
            try testAppendDictEntryString(message, "inner", "value");
            try closeDbusContainer(message);
            try closeDbusContainer(message);
            try closeDbusContainer(message);
        }
        try closeDbusContainer(message);
    }

    // arg 2: plain string array stays a sequence.
    {
        try openDbusContainer(message, systemd.SD_BUS_TYPE_ARRAY, "s");
        try appendDbusBasic(message, systemd.SD_BUS_TYPE_STRING, "x");
        try appendDbusBasic(message, systemd.SD_BUS_TYPE_STRING, "y");
        try closeDbusContainer(message);
    }

    // arg 3: struct stays a positional sequence.
    {
        try openDbusContainer(message, systemd.SD_BUS_TYPE_STRUCT, "is");
        var number: i32 = 5;
        try appendDbusBasic(message, systemd.SD_BUS_TYPE_INT32, &number);
        try appendDbusBasic(message, systemd.SD_BUS_TYPE_STRING, "s");
        try closeDbusContainer(message);
    }

    // arg 4: empty dict decodes to an empty table.
    {
        try openDbusContainer(message, systemd.SD_BUS_TYPE_ARRAY, "{sv}");
        try closeDbusContainer(message);
    }

    // arg 5: byte arrays decode to strings rather than one Lua number per byte.
    {
        try openDbusContainer(message, systemd.SD_BUS_TYPE_ARRAY, "y");
        for ([_]u8{ 0, 127, 255 }) |byte| {
            var value = byte;
            try appendDbusBasic(message, systemd.SD_BUS_TYPE_BYTE, &value);
        }
        try closeDbusContainer(message);
    }

    // arg 6: empty byte arrays are empty strings, not null pointers.
    {
        try openDbusContainer(message, systemd.SD_BUS_TYPE_ARRAY, "y");
        try closeDbusContainer(message);
    }
    try sealTestMessage(message);

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
