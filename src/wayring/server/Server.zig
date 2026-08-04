//! Server-owned publication registry and validated global bind boundary.
//!
//! Global records are heap-stable until Server deinitialization. Their typed
//! contexts are borrowed and are never destroyed by Server.

const Server = @This();

const std = @import("std");
const wire = @import("../wire.zig");
const Client = @import("Client.zig");
const Resource = @import("Resource.zig");
const Fatal = @import("fatal.zig");

pub const Global = opaque {
    pub fn name(self: *const Global) u32 {
        return globalRecord(self).global_name;
    }

    pub fn interface(self: *const Global) *const wire.Interface {
        return globalRecord(self).interface_descriptor;
    }

    pub fn version(self: *const Global) u32 {
        return globalRecord(self).advertised_version;
    }

    pub fn published(self: *const Global) bool {
        return globalRecord(self).is_published;
    }
};

const GlobalRecord = struct {
    global_name: u32,
    interface_descriptor: *const wire.Interface,
    advertised_version: u32,
    is_published: bool = true,
    context: *anyopaque,
    bind_erased: *const fn (*Client, u32, u32, *anyopaque) anyerror!void,
};

pub const Iterator = struct {
    server: *const Server,
    end: usize,
    index: usize = 0,

    pub fn next(self: *Iterator) ?*const Global {
        while (self.index < self.end) {
            const global = self.server.globals.items[self.index];
            self.index += 1;
            if (global.is_published) return globalHandle(global);
        }
        return null;
    }
};

allocator: std.mem.Allocator,
globals: std.ArrayList(*GlobalRecord) = .empty,
next_name: u32 = 1,
names_exhausted: bool = false,

pub fn init(allocator: std.mem.Allocator) Server {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Server) void {
    for (self.globals.items) |global| self.allocator.destroy(global);
    self.globals.deinit(self.allocator);
    self.* = undefined;
}

/// Publishes a global with a borrowed context. Names start at one and are
/// never reused, including after removal.
pub fn addGlobal(
    self: *Server,
    comptime ProtocolInterface: type,
    version_value: u32,
    comptime Context: type,
    context_value: *Context,
    comptime bind_value: *const fn (client: *Client, id: u32, version: u32, context: *Context) anyerror!void,
) !*const Global {
    if (version_value == 0 or version_value > ProtocolInterface.interface.version) return error.InvalidGlobalVersion;
    if (self.names_exhausted) return error.GlobalNameExhausted;
    const global = try self.allocator.create(GlobalRecord);
    errdefer self.allocator.destroy(global);
    global.* = .{
        .global_name = self.next_name,
        .interface_descriptor = &ProtocolInterface.interface,
        .advertised_version = version_value,
        .context = context_value,
        .bind_erased = struct {
            fn call(client: *Client, id: u32, version: u32, erased: *anyopaque) anyerror!void {
                return bind_value(client, id, version, @ptrCast(@alignCast(erased)));
            }
        }.call,
    };
    try self.globals.append(self.allocator, global);
    if (self.next_name == std.math.maxInt(u32)) self.names_exhausted = true else self.next_name += 1;
    return globalHandle(global);
}

/// Unpublishes a global. A second removal is reported as AlreadyRemoved;
/// pointers not owned by this Server are reported as ForeignGlobal.
pub fn removeGlobal(self: *Server, global: *const Global) !void {
    for (self.globals.items) |owned| if (globalHandle(owned) == global) {
        if (!owned.is_published) return error.AlreadyRemoved;
        owned.is_published = false;
        return;
    };
    return error.ForeignGlobal;
}

pub fn iterator(self: *const Server) Iterator {
    return .{ .server = self, .end = self.globals.items.len };
}

/// Validates registry and active generic-new_id state before entering the
/// typed binder. Requested versions are exact and are never clamped.
pub fn bind(self: *Server, client: *Client, name_value: u32, requested_interface: []const u8, requested_version: u32, id: u32) !void {
    var found: ?*GlobalRecord = null;
    for (self.globals.items) |global| if (global.global_name == name_value) {
        found = global;
        break;
    };
    const global = found orelse return error.UnknownGlobal;
    if (!global.is_published) return error.RemovedGlobal;
    if (!std.mem.eql(u8, global.interface_descriptor.name, requested_interface)) return error.InterfaceMismatch;
    if (requested_version == 0) return error.ZeroVersion;
    if (requested_version > global.advertised_version) return error.VersionTooHigh;
    try client.claimPendingGenericNewId(id, requested_interface, requested_version);
    return global.bind_erased(client, id, requested_version, global.context);
}

fn globalHandle(record: *GlobalRecord) *const Global {
    return @ptrCast(record);
}

fn globalRecord(handle: *const Global) *const GlobalRecord {
    return @ptrCast(@alignCast(handle));
}

const TestProtocol = struct {
    pub const interface: wire.Interface = .{ .name = "wl_test", .version = 3 };
    pub const request_messages: []const wire.MessageDescriptor = &.{};
};

const OtherProtocol = struct {
    pub const interface: wire.Interface = .{ .name = "wl_other", .version = 3 };
    pub const request_messages: []const wire.MessageDescriptor = &.{};
};

test "globals validate versions preserve stable monotonic publication order and borrow contexts" {
    const Context = struct {
        value: usize = 0,
        fn bind(_: *Client, _: u32, _: u32, self: *@This()) !void {
            self.value += 1;
        }
    };
    var server: Server = .init(std.testing.allocator);
    var context: Context = .{};
    try std.testing.expectError(error.InvalidGlobalVersion, server.addGlobal(TestProtocol, 0, Context, &context, Context.bind));
    try std.testing.expectError(error.InvalidGlobalVersion, server.addGlobal(TestProtocol, 4, Context, &context, Context.bind));
    const first = try server.addGlobal(TestProtocol, 3, Context, &context, Context.bind);
    const second = try server.addGlobal(TestProtocol, 1, Context, &context, Context.bind);
    try std.testing.expectEqual(@as(u32, 1), first.name());
    try std.testing.expectEqual(@as(u32, 2), second.name());
    try server.removeGlobal(first);
    try std.testing.expectError(error.AlreadyRemoved, server.removeGlobal(first));
    var snapshot = server.iterator();
    const third = try server.addGlobal(TestProtocol, 2, Context, &context, Context.bind);
    try std.testing.expectEqual(@as(u32, 3), third.name());
    try std.testing.expectEqual(second, snapshot.next().?);
    try std.testing.expect(snapshot.next() == null);
    var iter = server.iterator();
    try std.testing.expectEqual(second, iter.next().?);
    try std.testing.expectEqual(third, iter.next().?);
    try std.testing.expect(iter.next() == null);
    server.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.value);
}

test "bind rejects each validation boundary before binder entry" {
    const Context = struct {
        calls: usize = 0,
        fn bind(_: *Client, _: u32, _: u32, self: *@This()) !void {
            self.calls += 1;
        }
    };
    var server: Server = .init(std.testing.allocator);
    defer server.deinit();
    var client: Client = .init(std.testing.allocator, .{});
    defer client.deinit();
    var context: Context = .{};
    const live = try server.addGlobal(TestProtocol, 2, Context, &context, Context.bind);
    const removed = try server.addGlobal(TestProtocol, 2, Context, &context, Context.bind);
    try server.removeGlobal(removed);
    try std.testing.expectError(error.UnknownGlobal, server.bind(&client, 99, "wl_test", 1, 2));
    try std.testing.expectError(error.RemovedGlobal, server.bind(&client, removed.name(), "wl_test", 1, 2));
    try std.testing.expectError(error.InterfaceMismatch, server.bind(&client, live.name(), "wl_other", 1, 2));
    try std.testing.expectError(error.ZeroVersion, server.bind(&client, live.name(), "wl_test", 0, 2));
    try std.testing.expectError(error.VersionTooHigh, server.bind(&client, live.name(), "wl_test", 3, 2));
    try std.testing.expectError(error.OutsideDispatch, server.bind(&client, live.name(), "wl_test", 2, 2));
    try std.testing.expectEqual(@as(usize, 0), context.calls);
}

fn frame(descriptor: *const wire.MessageDescriptor, values: []const wire.Value) ![]u8 {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(1, 0, descriptor, values);
    const batch = (try output.beginSend()).?;
    const bytes = try std.testing.allocator.dupe(u8, batch.bytes);
    try output.completeSend(batch.token, batch.bytes.len);
    return bytes;
}

test "generic new_id dispatch binds exact typed resource and classifies binder failures" {
    const request: wire.MessageDescriptor = .{ .name = "bind", .arguments = &.{.{ .name = "id", .kind = .{ .new_id = null } }} };
    const RootInterface: wire.Interface = .{ .name = "wl_root", .version = 1 };
    const BindContext = struct {
        resource: ?Resource = null,
        calls: usize = 0,
        fail: bool = false,
        mode: enum { exact, missing, wrong_interface, wrong_version, reentrant } = .exact,
        server: ?*Server = null,
        global: ?*const Global = null,
        fn bind(client: *Client, id: u32, version: u32, self: *@This()) !void {
            self.calls += 1;
            if (self.fail) return error.BinderFailed;
            if (self.mode == .reentrant)
                return self.server.?.bind(client, self.global.?.name(), "wl_test", version, id);
            if (self.mode == .missing) return;
            const interface = if (self.mode == .wrong_interface) &OtherProtocol.interface else &TestProtocol.interface;
            const actual_version: u32 = if (self.mode == .wrong_version) 1 else version;
            self.resource = .init(std.testing.allocator, id, actual_version, interface, &.{}, .client, client.ownerHooks());
            try client.materialize(&self.resource.?);
        }
    };
    const Handler = struct {
        server: *Server,
        client: *Client,
        global: *const Global,
        fn handle(self: *@This(), _: *Resource, _: u16, message: *wire.DecodedMessage) !void {
            const value = message.values[0].new_id.generic;
            try self.server.bind(self.client, self.global.name(), value.interface, value.version, value.id);
        }
    };
    const Case = struct {
        fn run(fail: bool, mode: @FieldType(BindContext, "mode"), succeeds: bool) !void {
            var server: Server = .init(std.testing.allocator);
            defer server.deinit();
            var client: Client = .init(std.testing.allocator, .{});
            defer client.deinit();
            var bind_context: BindContext = .{ .fail = fail, .mode = mode };
            const global = try server.addGlobal(TestProtocol, 3, BindContext, &bind_context, BindContext.bind);
            bind_context.server = &server;
            bind_context.global = global;
            var handler: Handler = .{ .server = &server, .client = &client, .global = global };
            var root: Resource = .init(std.testing.allocator, 1, 1, &RootInterface, &.{request}, .client, client.ownerHooks());
            try root.setHandler(Handler, &handler, Handler.handle, null);
            try client.installClientInitial(1, &root);
            const bytes = try frame(&request, &.{.{ .new_id = .{ .generic = .{ .interface = "wl_test", .version = 2, .id = 2 } } }});
            defer std.testing.allocator.free(bytes);
            try client.receive(bytes, &.{});
            try client.dispatch();
            try std.testing.expectEqual(@as(usize, 1), bind_context.calls);
            if (succeeds) {
                try std.testing.expect(client.fatal() == null);
                try std.testing.expectEqual(@as(u32, 2), bind_context.resource.?.version());
                try std.testing.expectEqual(&bind_context.resource.?, client.lookup(2).?);
                bind_context.resource.?.destroy();
                bind_context.resource.?.deinit();
            } else try std.testing.expectEqual(Fatal.Kind.implementation, client.fatal().?.kind);
        }
    };
    try Case.run(false, .exact, true);
    try Case.run(true, .exact, false);
    try Case.run(false, .missing, false);
    try Case.run(false, .wrong_interface, false);
    try Case.run(false, .wrong_version, false);
    try Case.run(false, .reentrant, false);
}
