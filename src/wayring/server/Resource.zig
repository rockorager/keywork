//! Stable server object state, erased request handling, and destruction hooks.
//!
//! Storage for a Resource is supplied by its owner and must remain stable until
//! after synchronous destruction. Handler, observer, and owner contexts are
//! borrowed; their owners must keep them alive for the applicable registration
//! or Resource lifetime.

const Resource = @This();

const std = @import("std");
const wire = @import("../wire.zig");
const ObjectMap = @import("object_map.zig");

pub const State = enum { live, destroying, dead };

pub const OwnerHooks = struct {
    context: *anyopaque,
    retire: *const fn (context: *anyopaque, resource: *Resource) void,
    emit: *const fn (
        context: *anyopaque,
        resource: *Resource,
        opcode: u16,
        descriptor: *const wire.MessageDescriptor,
        values: []const wire.Value,
    ) anyerror!void,
};

pub const DispatchError = error{
    ResourceNotLive,
    NoHandler,
    RecursiveDispatch,
};

/// Opaque, runtime-owned destruction registration handle.
pub const Observer = opaque {};

const ObserverNode = struct {
    resource: *Resource,
    context: *anyopaque,
    notify: *const fn (*anyopaque, *Resource, *Observer) void,
    previous: ?*ObserverNode = null,
    next: ?*ObserverNode = null,
    active: bool = true,
};

const ErasedHandler = struct {
    context: *anyopaque,
    dispatch: *const fn (*anyopaque, *Resource, u16, *wire.DecodedMessage) anyerror!void,
    destroy_context: ?*const fn (*anyopaque, *Resource) void,
};

allocator: std.mem.Allocator,
object_id: u32,
negotiated_version: u32,
interface_descriptor: *const wire.Interface,
request_descriptors: []const wire.MessageDescriptor,
object_origin: ObjectMap.Origin,
owner: OwnerHooks,
resource_state: State = .live,
handler: ?ErasedHandler = null,
active_dispatch: ?*bool = null,
observer_head: ?*ObserverNode = null,
observer_tail: ?*ObserverNode = null,
notifying: bool = false,

pub fn init(
    allocator: std.mem.Allocator,
    object_id: u32,
    negotiated_version: u32,
    interface_descriptor: *const wire.Interface,
    request_descriptors_value: []const wire.MessageDescriptor,
    object_origin_value: ObjectMap.Origin,
    owner: OwnerHooks,
) Resource {
    std.debug.assert(object_id != 0);
    std.debug.assert(negotiated_version != 0 and negotiated_version <= interface_descriptor.version);
    return .{
        .allocator = allocator,
        .object_id = object_id,
        .negotiated_version = negotiated_version,
        .interface_descriptor = interface_descriptor,
        .request_descriptors = request_descriptors_value,
        .object_origin = object_origin_value,
        .owner = owner,
    };
}

pub fn requests(self: *const Resource) []const wire.MessageDescriptor {
    return self.request_descriptors;
}

pub fn id(self: *const Resource) u32 {
    return self.object_id;
}

pub fn version(self: *const Resource) u32 {
    return self.negotiated_version;
}

pub fn interface(self: *const Resource) *const wire.Interface {
    return self.interface_descriptor;
}

pub fn origin(self: *const Resource) ObjectMap.Origin {
    return self.object_origin;
}

pub fn state(self: *const Resource) State {
    return self.resource_state;
}

/// Tests the complete owner identity; mixing a context with foreign function
/// hooks is never considered ownership by this Resource.
pub fn ownedBy(self: *const Resource, hooks: OwnerHooks) bool {
    return self.owner.context == hooks.context and
        self.owner.retire == hooks.retire and self.owner.emit == hooks.emit;
}

pub fn setHandler(
    self: *Resource,
    comptime Context: type,
    context: *Context,
    comptime handler: *const fn (*Context, *Resource, u16, *wire.DecodedMessage) anyerror!void,
    comptime destructor: ?*const fn (*Resource, *Context) void,
) !void {
    if (self.resource_state != .live) return error.ResourceNotLive;
    if (self.handler != null) return error.HandlerAlreadySet;
    self.handler = .{
        .context = context,
        .dispatch = struct {
            fn call(erased: *anyopaque, resource: *Resource, opcode: u16, message: *wire.DecodedMessage) anyerror!void {
                return handler(@ptrCast(@alignCast(erased)), resource, opcode, message);
            }
        }.call,
        .destroy_context = if (destructor) |destroy_typed| struct {
            fn call(erased: *anyopaque, resource: *Resource) void {
                destroy_typed(resource, @ptrCast(@alignCast(erased)));
            }
        }.call else null,
    };
}

/// Explicitly clears the handler and runs its optional context destructor.
/// Calling this from the handler is terminal for its context: the handler must
/// not dereference that context after this function returns.
pub fn clearHandler(self: *Resource) void {
    const handler = self.handler orelse return;
    self.handler = null;
    if (handler.destroy_context) |destroy_context| destroy_context(handler.context, self);
}

/// Dispatch errors identify lifecycle misuse; handler errors pass through.
pub fn dispatchErased(self: *Resource, opcode: u16, message: *wire.DecodedMessage) anyerror!void {
    if (self.resource_state != .live) return error.ResourceNotLive;
    if (self.active_dispatch != null) return error.RecursiveDispatch;
    const handler = self.handler orelse return error.NoHandler;

    // The callback may destroy and arrange reclamation of Resource and its
    // context. A stack token lets destruction clear recursion state without
    // dispatch touching Resource storage after the callback returns.
    const callback = handler.dispatch;
    const context = handler.context;
    var destroyed = false;
    self.active_dispatch = &destroyed;
    const result = callback(context, self, opcode, message);
    if (!destroyed) self.active_dispatch = null;
    return result;
}

pub fn addDestroyObserver(
    self: *Resource,
    comptime Context: type,
    context: *Context,
    comptime callback: *const fn (*Context, *Resource, *Observer) void,
) !*Observer {
    if (self.resource_state != .live) return error.ResourceNotLive;
    const observer = try self.allocator.create(ObserverNode);
    observer.* = .{
        .resource = self,
        .context = context,
        .notify = struct {
            fn call(erased: *anyopaque, resource: *Resource, handle: *Observer) void {
                callback(@ptrCast(@alignCast(erased)), resource, handle);
            }
        }.call,
        .previous = self.observer_tail,
    };
    if (self.observer_tail) |tail| tail.next = observer else self.observer_head = observer;
    self.observer_tail = observer;
    return @ptrCast(observer);
}

/// The handle is invalid immediately after removal, except while destruction
/// notification is active, when reclamation is deferred until it completes.
pub fn removeDestroyObserver(observer: *Observer) void {
    const node: *ObserverNode = @ptrCast(@alignCast(observer));
    if (!node.active) return;
    const self = node.resource;
    node.active = false;
    if (self.notifying) return;
    self.unlinkAndFree(node);
}

/// Synchronously destroys handler context. A handler that destroys its own
/// resource must not dereference that context afterward.
pub fn destroy(self: *Resource) void {
    if (self.resource_state != .live) return;
    self.resource_state = .destroying;
    if (self.active_dispatch) |destroyed| {
        destroyed.* = true;
        self.active_dispatch = null;
    }
    self.notifying = true;
    var current = self.observer_head;
    while (current) |observer| {
        const next = observer.next;
        if (observer.active) observer.notify(observer.context, self, @ptrCast(observer));
        current = next;
    }
    self.notifying = false;
    self.freeAllObservers();
    self.clearHandler();
    self.owner.retire(self.owner.context, self);
    self.resource_state = .dead;
}

pub fn emit(
    self: *Resource,
    opcode: u16,
    descriptor: *const wire.MessageDescriptor,
    values: []const wire.Value,
) !void {
    if (self.resource_state != .live) return error.ResourceNotLive;
    try self.owner.emit(self.owner.context, self, opcode, descriptor, values);
}

/// Resource storage may be reclaimed after this call. Destruction must already
/// have synchronously retired it from its borrowed owner.
pub fn deinit(self: *Resource) void {
    std.debug.assert(self.resource_state == .dead);
    std.debug.assert(self.observer_head == null and self.observer_tail == null);
    self.* = undefined;
}

fn unlinkAndFree(self: *Resource, observer: *ObserverNode) void {
    if (observer.previous) |previous| previous.next = observer.next else self.observer_head = observer.next;
    if (observer.next) |next| next.previous = observer.previous else self.observer_tail = observer.previous;
    self.allocator.destroy(observer);
}

fn freeAllObservers(self: *Resource) void {
    var current = self.observer_head;
    while (current) |observer| {
        const next = observer.next;
        self.allocator.destroy(observer);
        current = next;
    }
    self.observer_head = null;
    self.observer_tail = null;
}

const TestOwner = struct {
    order: std.ArrayList(u8) = .empty,
    retire_count: usize = 0,
    emitted: bool = false,

    fn retire(erased: *anyopaque, resource: *Resource) void {
        const self: *TestOwner = @ptrCast(@alignCast(erased));
        std.debug.assert(resource.state() == .destroying);
        self.retire_count += 1;
        self.order.append(std.testing.allocator, 'r') catch unreachable;
    }

    fn emit(erased: *anyopaque, resource: *Resource, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
        const self: *TestOwner = @ptrCast(@alignCast(erased));
        try std.testing.expectEqual(@as(u32, 71), resource.id());
        try std.testing.expectEqual(@as(u16, 9), opcode);
        try std.testing.expectEqualStrings("event", descriptor.name);
        try std.testing.expectEqual(@as(u32, 44), values[0].uint);
        self.emitted = true;
    }

    fn hooks(self: *TestOwner) OwnerHooks {
        return .{ .context = self, .retire = TestOwner.retire, .emit = TestOwner.emit };
    }
};

const test_interface: wire.Interface = .{ .name = "test", .version = 3 };
const test_message: wire.MessageDescriptor = .{ .name = "request", .arguments = &.{} };

fn testDecoded() wire.DecodedMessage {
    return .{ .allocator = std.testing.allocator, .descriptor = &test_message, .body = &.{}, .values = &.{} };
}

test "typed borrowed handler can destroy itself and context destructor runs once" {
    const Trace = struct {
        called: usize = 0,
        destroyed: usize = 0,
        metadata_after_destroy: bool = false,
    };
    const Context = struct {
        expected_message: *wire.DecodedMessage,
        trace: *Trace,

        fn handle(self: *@This(), resource: *Resource, opcode: u16, message: *wire.DecodedMessage) !void {
            try std.testing.expectEqual(self.expected_message, message);
            try std.testing.expectEqual(@as(u16, 12), opcode);
            const trace = self.trace;
            trace.called += 1;
            resource.destroy();
            trace.metadata_after_destroy = resource.id() == 71 and resource.interface() == &test_interface and resource.state() == .dead;
        }
        fn deinit(_: *Resource, self: *@This()) void {
            self.trace.destroyed += 1;
        }
    };
    var owner: TestOwner = .{};
    defer owner.order.deinit(std.testing.allocator);
    var resource = init(std.testing.allocator, 71, 2, &test_interface, &.{test_message}, .client, owner.hooks());
    var message = testDecoded();
    var trace: Trace = .{};
    var context: Context = .{ .expected_message = &message, .trace = &trace };
    try resource.setHandler(Context, &context, Context.handle, Context.deinit);
    try resource.dispatchErased(12, &message);
    try std.testing.expectEqual(@as(usize, 1), trace.called);
    try std.testing.expectEqual(@as(usize, 1), trace.destroyed);
    try std.testing.expect(trace.metadata_after_destroy);
    resource.destroy();
    try std.testing.expectEqual(@as(usize, 1), trace.destroyed);
    resource.deinit();
}

test "observers retain order and removal during notification skips future observers" {
    const Context = struct {
        order: *std.ArrayList(u8),
        future: ?*Observer = null,
        label: u8,
        fn observe(self: *@This(), _: *Resource, handle: *Observer) void {
            self.order.append(std.testing.allocator, self.label) catch unreachable;
            if (self.label == 'a') {
                removeDestroyObserver(handle);
                removeDestroyObserver(self.future.?);
            }
        }
    };
    var owner: TestOwner = .{};
    defer owner.order.deinit(std.testing.allocator);
    var resource = init(std.testing.allocator, 71, 1, &test_interface, &.{test_message}, .server, owner.hooks());
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var first: Context = .{ .order = &order, .label = 'a' };
    var second: Context = .{ .order = &order, .label = 'b' };
    var third: Context = .{ .order = &order, .label = 'c' };
    _ = try resource.addDestroyObserver(Context, &first, Context.observe);
    _ = try resource.addDestroyObserver(Context, &second, Context.observe);
    first.future = try resource.addDestroyObserver(Context, &third, Context.observe);
    resource.destroy();
    try std.testing.expectEqualStrings("ab", order.items);
    resource.deinit();
}

test "recursive dispatch no handler and dead dispatch are rejected" {
    const Context = struct {
        calls: usize = 0,
        fn handle(self: *@This(), resource: *Resource, opcode: u16, message: *wire.DecodedMessage) !void {
            self.calls += 1;
            try std.testing.expectError(error.RecursiveDispatch, resource.dispatchErased(opcode, message));
        }
    };
    var owner: TestOwner = .{};
    defer owner.order.deinit(std.testing.allocator);
    var resource = init(std.testing.allocator, 71, 1, &test_interface, &.{test_message}, .client, owner.hooks());
    var message = testDecoded();
    try std.testing.expectError(error.NoHandler, resource.dispatchErased(0, &message));
    var context: Context = .{};
    try resource.setHandler(Context, &context, Context.handle, null);
    try resource.dispatchErased(0, &message);
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    resource.destroy();
    try std.testing.expectError(error.ResourceNotLive, resource.dispatchErased(0, &message));
    resource.deinit();
}

test "destroy orders observers destructor and retirement and retires once" {
    const Context = struct {
        order: *std.ArrayList(u8),
        fn observe(self: *@This(), _: *Resource, _: *Observer) void {
            self.order.append(std.testing.allocator, 'o') catch unreachable;
        }
        fn handle(_: *@This(), _: *Resource, _: u16, _: *wire.DecodedMessage) !void {}
        fn deinit(_: *Resource, self: *@This()) void {
            self.order.append(std.testing.allocator, 'd') catch unreachable;
        }
    };
    var owner: TestOwner = .{};
    defer owner.order.deinit(std.testing.allocator);
    var resource = init(std.testing.allocator, 71, 1, &test_interface, &.{test_message}, .client, owner.hooks());
    var context: Context = .{ .order = &owner.order };
    try resource.setHandler(Context, &context, Context.handle, Context.deinit);
    _ = try resource.addDestroyObserver(Context, &context, Context.observe);
    resource.destroy();
    resource.destroy();
    try std.testing.expectEqualStrings("odr", owner.order.items);
    try std.testing.expectEqual(@as(usize, 1), owner.retire_count);
    resource.deinit();
}

test "emit forwards while live and rejects destroying and dead resources" {
    const Context = struct {
        fn observe(_: *@This(), resource: *Resource, _: *Observer) void {
            const descriptor: wire.MessageDescriptor = .{ .name = "event", .arguments = &.{} };
            std.testing.expectError(error.ResourceNotLive, resource.emit(0, &descriptor, &.{})) catch unreachable;
        }
    };
    const descriptor: wire.MessageDescriptor = .{ .name = "event", .arguments = &.{.{ .name = "value", .kind = .uint }} };
    var owner: TestOwner = .{};
    defer owner.order.deinit(std.testing.allocator);
    var resource = init(std.testing.allocator, 71, 1, &test_interface, &.{test_message}, .server, owner.hooks());
    try resource.emit(9, &descriptor, &.{.{ .uint = 44 }});
    try std.testing.expect(owner.emitted);
    var context: Context = .{};
    _ = try resource.addDestroyObserver(Context, &context, Context.observe);
    resource.destroy();
    try std.testing.expectError(error.ResourceNotLive, resource.emit(9, &descriptor, &.{.{ .uint = 44 }}));
    resource.deinit();
}
