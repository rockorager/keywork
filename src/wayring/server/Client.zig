//! Sans-I/O state and request dispatch for one Wayland client connection.
//!
//! Resources and handler contexts are borrowed. They must remain stable while
//! live; Client never deinitializes or frees them. A handler that takes an FD
//! owns it even when that handler subsequently returns an error. Client storage
//! must remain stable after registering a destruction observer.

const Client = @This();

const std = @import("std");
const wire = @import("../wire.zig");
const Resource = @import("Resource.zig");
const ObjectMap = @import("object_map.zig");
const Fatal = @import("fatal.zig");

pub const Credentials = struct {
    pid: std.os.linux.pid_t,
    uid: std.os.linux.uid_t,
    gid: std.os.linux.gid_t,
};

/// Server-assigned origin of the transport that accepted this client.
pub const TransportProvenance = enum {
    unknown,
    direct,
    security_context,
};

pub const ProtocolDirection = enum { request, event };

pub const ProtocolMessage = struct {
    direction: ProtocolDirection,
    resource: *Resource,
    opcode: u16,
    descriptor: *const wire.MessageDescriptor,
    values: []const wire.Value,
};

pub const PreparedEvent = struct {
    resource: *Resource,
    opcode: u16,
    descriptor: *const wire.MessageDescriptor,
    values: []const wire.Value,
};

pub const ProtocolLogSink = struct {
    context: *anyopaque,
    notify: *const fn (*anyopaque, *Client, ProtocolMessage) void,
};

pub const Options = struct {
    max_objects: usize = 4096,
    credentials: ?Credentials = null,
    transport_provenance: TransportProvenance = .unknown,
    protocol_log_sink: ?ProtocolLogSink = null,
};

/// Opaque, runtime-owned destruction registration handle.
pub const Observer = opaque {};

/// Opaque registration notified synchronously before the first fatal is recorded.
pub const TerminalObserver = opaque {};

const ObserverNode = struct {
    client: *Client,
    context: *anyopaque,
    notify: *const fn (*anyopaque, *Client, *Observer) void,
    previous: ?*ObserverNode = null,
    next: ?*ObserverNode = null,
    active: bool = true,
};

const TerminalObserverNode = struct {
    client: *Client,
    context: *anyopaque,
    notify: *const fn (*anyopaque, *Client, *TerminalObserver) void,
    previous: ?*TerminalObserverNode = null,
    next: ?*TerminalObserverNode = null,
    active: bool = true,
};

const delete_id_descriptor: wire.MessageDescriptor = .{
    .name = "delete_id",
    .arguments = &.{.{ .name = "id", .kind = .uint }},
};

const display_error_descriptor: wire.MessageDescriptor = .{
    .name = "error",
    .arguments = &.{
        .{ .name = "object_id", .kind = .{ .object = .{} } },
        .{ .name = "code", .kind = .uint },
        .{ .name = "message", .kind = .{ .string = .required } },
    },
};

const NewIdExpectation = struct {
    const State = enum { pending, binding, materialized };

    id: u32,
    interface: ?*const wire.Interface,
    generic_name: ?[]const u8,
    generic_version: ?u32,
    state: State = .pending,
};

allocator: std.mem.Allocator,
input: wire.Input,
output: wire.Output,
objects: ObjectMap,
credentials_value: ?Credentials,
transport_provenance_value: TransportProvenance,
protocol_log_sink: ?ProtocolLogSink,
fatal_state: Fatal = .{},
dispatching: bool = false,
active_new_ids: ?[]NewIdExpectation = null,
observer_head: ?*ObserverNode = null,
observer_tail: ?*ObserverNode = null,
terminal_observer_head: ?*TerminalObserverNode = null,
terminal_observer_tail: ?*TerminalObserverNode = null,
notifying_destroy: bool = false,
notifying_terminal: bool = false,
terminalizing: bool = false,
destroying: bool = false,

pub fn init(allocator: std.mem.Allocator, options: Options) Client {
    return .{
        .allocator = allocator,
        .input = .init(allocator),
        .output = .init(allocator),
        .objects = .init(allocator, .{ .max_objects = options.max_objects }),
        .credentials_value = options.credentials,
        .transport_provenance_value = options.transport_provenance,
        .protocol_log_sink = options.protocol_log_sink,
    };
}

/// Notifies destruction observers, then releases connection-owned queues and
/// tables, but never borrowed Resources.
pub fn deinit(self: *Client) void {
    if (self.destroying) return;
    self.destroying = true;
    self.notifying_destroy = true;
    var current = self.observer_head;
    while (current) |observer| {
        const next = observer.next;
        if (observer.active) observer.notify(observer.context, self, @ptrCast(observer));
        current = next;
    }
    self.notifying_destroy = false;
    self.freeAllObservers();
    self.input.deinit();
    self.output.deinit();
    self.objects.deinit();
    self.* = undefined;
}

pub fn fatal(self: *const Client) ?*const Fatal {
    return if (self.fatal_state.recorded) &self.fatal_state else null;
}

pub fn objectCount(self: *const Client) usize {
    return self.objects.count();
}

/// Returns immutable transport-supplied peer metadata, when available.
/// Consumers remain responsible for any authorization decision.
pub fn credentials(self: *const Client) ?Credentials {
    return self.credentials_value;
}

/// Returns immutable provenance assigned by the accepting server transport.
pub fn transportProvenance(self: *const Client) TransportProvenance {
    return self.transport_provenance_value;
}

pub fn addDestroyObserver(
    self: *Client,
    comptime Context: type,
    context: *Context,
    comptime callback: *const fn (*Context, *Client, *Observer) void,
) !*Observer {
    if (self.destroying) return error.ClientDestroying;
    const observer = try self.allocator.create(ObserverNode);
    observer.* = .{
        .client = self,
        .context = context,
        .notify = struct {
            fn call(erased: *anyopaque, client: *Client, handle: *Observer) void {
                callback(@ptrCast(@alignCast(erased)), client, handle);
            }
        }.call,
        .previous = self.observer_tail,
    };
    if (self.observer_tail) |tail| tail.next = observer else self.observer_head = observer;
    self.observer_tail = observer;
    return @ptrCast(observer);
}

/// The handle is invalid immediately after removal, except during destruction
/// notification, when reclamation is deferred until all callbacks complete.
pub fn removeDestroyObserver(observer: *Observer) void {
    const node: *ObserverNode = @ptrCast(@alignCast(observer));
    if (!node.active) return;
    const self = node.client;
    node.active = false;
    if (self.notifying_destroy) return;
    self.unlinkAndFreeObserver(node);
}

pub fn addTerminalObserver(
    self: *Client,
    comptime Context: type,
    context: *Context,
    comptime callback: *const fn (*Context, *Client, *TerminalObserver) void,
) !*TerminalObserver {
    if (self.destroying) return error.ClientDestroying;
    if (self.fatal_state.recorded or self.terminalizing) return error.ClientTerminal;
    const observer = try self.allocator.create(TerminalObserverNode);
    observer.* = .{
        .client = self,
        .context = context,
        .notify = struct {
            fn call(erased: *anyopaque, client: *Client, handle: *TerminalObserver) void {
                callback(@ptrCast(@alignCast(erased)), client, handle);
            }
        }.call,
        .previous = self.terminal_observer_tail,
    };
    if (self.terminal_observer_tail) |tail| tail.next = observer else self.terminal_observer_head = observer;
    self.terminal_observer_tail = observer;
    return @ptrCast(observer);
}

pub fn removeTerminalObserver(observer: *TerminalObserver) void {
    const node: *TerminalObserverNode = @ptrCast(@alignCast(observer));
    if (!node.active) return;
    const self = node.client;
    node.active = false;
    if (self.notifying_terminal) return;
    self.unlinkAndFreeTerminalObserver(node);
}

/// Records an application-detected protocol violation without allocating and
/// prevents any further request dispatch.
pub fn postProtocolError(self: *Client, resource: *Resource, code: u32, detail: []const u8) void {
    self.recordDetails(.{
        .kind = .protocol,
        .object_id = resource.id(),
        .protocol_code = code,
        .interface = resource.interface(),
        .detail = detail,
    });
}

/// Records allocation failure associated with a resource. First fatal wins.
pub fn postOutOfMemory(self: *Client, resource: *Resource, detail: []const u8) void {
    self.record(.out_of_memory, resource.id(), null, resource.interface(), detail);
}

/// Records an implementation failure associated with a resource. First fatal wins.
pub fn postImplementationError(self: *Client, resource: *Resource, detail: []const u8) void {
    self.record(.implementation, resource.id(), null, resource.interface(), detail);
}

/// Records malformed input detected by a transport adapter without allocating.
pub fn transportMalformed(self: *Client) void {
    self.record(.malformed_wire, 0, null, null, "malformed transport input");
}

/// Records allocation failure in a transport adapter without allocating.
pub fn transportOutOfMemory(self: *Client) void {
    self.record(.out_of_memory, 0, null, null, "transport allocation failed");
}

/// Records peer closure without producing a terminal protocol frame.
pub fn peerDisconnected(self: *Client) void {
    self.record(.peer_disconnect, 0, null, null, "peer disconnected");
}

pub fn receive(self: *Client, bytes: []const u8, fds: []const wire.FileDescriptor) !void {
    if (self.fatal_state.recorded) return error.ClientFatal;
    self.input.receive(bytes, fds) catch |err| {
        self.record(.out_of_memory, 0, null, null, "receiving input");
        return err;
    };
}

pub fn beginSend(self: *Client) !?wire.SendBatch {
    return self.output.beginSend();
}

pub fn hasPendingOutput(self: *const Client) bool {
    return self.output.hasPendingOutput();
}

pub fn completeSend(self: *Client, token: wire.BatchToken, bytes_written: usize) !void {
    return self.output.completeSend(token, bytes_written);
}

/// Reserves transport storage before a semantic configure token or wire serial
/// is issued. The returned batch must be published or canceled.
pub fn prepareEvents(self: *Client, maximum_bytes: usize) !wire.PreparedBatch {
    if (self.fatal_state.recorded) return error.ClientFatal;
    return self.output.prepareBatch(maximum_bytes);
}

pub fn cancelPreparedEvents(self: *Client, prepared: wire.PreparedBatch) void {
    self.output.cancelPreparedBatch(prepared);
}

/// Encodes and publishes a complete descriptor-free event sequence without
/// allocation. Logging occurs only after the whole sequence is visible.
pub fn emitPreparedEvents(
    self: *Client,
    prepared: wire.PreparedBatch,
    events: []const PreparedEvent,
) !void {
    if (self.fatal_state.recorded) return error.ClientFatal;
    if (events.len == 0) return error.EmptyPreparedBatch;
    for (events) |event| {
        if (event.resource.state() != .live or !event.resource.ownedBy(self.ownerHooks())) {
            return error.InvalidResourceIdentity;
        }
        const installed = self.objects.lookup(event.resource.id()) orelse
            return error.InvalidResourceIdentity;
        if (installed.resource != @as(*anyopaque, @ptrCast(event.resource)) or
            installed.origin != event.resource.origin())
        {
            return error.InvalidResourceIdentity;
        }
        if (event.values.len != event.descriptor.arguments.len) {
            return error.InvalidEventDescriptor;
        }
    }

    var writer = std.Io.Writer.fixed(try self.output.preparedBatchStorage(prepared));
    for (events) |event| try wire.encodePreparedMessage(
        &writer,
        event.resource.id(),
        event.opcode,
        event.descriptor,
        event.values,
    );
    try self.output.publishPreparedBatch(prepared, writer.buffered().len);
    for (events) |event| self.logProtocol(.{
        .direction = .event,
        .resource = event.resource,
        .opcode = event.opcode,
        .descriptor = event.descriptor,
        .values = event.values,
    });
}

pub fn ownerHooks(self: *Client) Resource.OwnerHooks {
    return .{ .context = self, .retire = retire, .emit = emit };
}

/// Claims a generic new_id for one registry bind. The claim prevents binder
/// reentrancy and remains held until materialization or request failure.
pub fn claimPendingGenericNewId(self: *Client, id: u32, interface_name: []const u8, version: u32) !void {
    const expectations = self.active_new_ids orelse return error.OutsideDispatch;
    for (expectations) |*expectation| if (expectation.id == id) {
        if (expectation.state != .pending) return error.NotExpectedNewId;
        if (expectation.interface != null) return error.ExpectedTypedNewId;
        if (!std.mem.eql(u8, expectation.generic_name.?, interface_name) or expectation.generic_version.? != version)
            return error.WrongGenericNewId;
        expectation.state = .binding;
        return;
    };
    return error.NotExpectedNewId;
}

/// Materializes an ID reserved by the currently dispatched request.
pub fn materialize(self: *Client, resource: *Resource) !void {
    if (resource.origin() != .client or resource.state() != .live or !resource.ownedBy(self.ownerHooks()))
        return error.InvalidClientResource;
    const expectations = self.active_new_ids orelse return error.OutsideDispatch;
    var expectation: ?*NewIdExpectation = null;
    for (expectations) |*candidate| if (candidate.id == resource.id()) {
        expectation = candidate;
        break;
    };
    const expected = expectation orelse return error.NotExpectedNewId;
    if (expected.state == .materialized) return error.NotExpectedNewId;
    if (expected.interface) |interface| {
        if (!sameInterface(interface, resource.interface())) return error.WrongNewIdInterface;
    } else {
        if (!std.mem.eql(u8, expected.generic_name.?, resource.interface().name) or
            expected.generic_version.? != resource.version()) return error.WrongGenericNewId;
    }
    try self.objects.materializeClient(resource.id(), resource);
    expected.state = .materialized;
}

/// Installs a bootstrap client object (not a request-provided new_id).
pub fn installClientInitial(self: *Client, id: u32, resource: *Resource) !void {
    if (resource.id() != id or resource.origin() != .client or resource.state() != .live or !resource.ownedBy(self.ownerHooks())) return error.InvalidInitialResource;
    try self.objects.reserveClientIds(&.{id});
    errdefer self.objects.rollbackClientReservations(&.{id});
    try self.objects.materializeClient(id, resource);
}

pub fn reserveServerId(self: *Client) !u32 {
    return self.objects.reserveServerId();
}

pub fn materializeServer(self: *Client, resource: *Resource) !void {
    if (resource.origin() != .server or resource.state() != .live or !resource.ownedBy(self.ownerHooks())) return error.InvalidServerResource;
    try self.objects.materializeServer(resource.id(), resource);
}

pub fn rollbackServerId(self: *Client, id: u32) void {
    self.objects.rollbackServerId(id);
}

pub fn lookup(self: *Client, id: u32) ?*Resource {
    const live = self.objects.lookup(id) orelse return null;
    return @ptrCast(@alignCast(live.resource));
}

pub fn dispatch(self: *Client) !void {
    if (self.dispatching) return error.DispatchInProgress;
    if (self.fatal_state.recorded) return;
    self.dispatching = true;
    defer self.dispatching = false;

    while (!self.fatal_state.recorded) {
        const header = self.input.peekFrame() catch {
            self.failMalformed(0, null, "invalid frame header");
            return;
        } orelse return;
        const target = self.lookup(header.object_id) orelse {
            self.failProtocol(header.object_id, header.opcode, null, "unknown object");
            return;
        };
        const interface = target.interface();
        const version = target.version();
        const requests = target.requests();
        if (header.opcode >= requests.len) {
            self.failProtocol(header.object_id, header.opcode, interface, "unknown opcode");
            return;
        }
        const descriptor = &requests[header.opcode];
        if (descriptor.since > version) {
            self.failProtocol(header.object_id, header.opcode, interface, "request unsupported by object version");
            return;
        }

        var message = self.input.decodeNext(descriptor) catch |err| switch (err) {
            error.NeedMoreBytes, error.NeedMoreFileDescriptors => return,
            error.OutOfMemory => {
                self.record(.out_of_memory, header.object_id, header.opcode, interface, "decoding request");
                return;
            },
            else => {
                self.failMalformed(header.object_id, header.opcode, "malformed request arguments");
                return;
            },
        };
        defer message.deinit();

        self.logProtocol(.{
            .direction = .request,
            .resource = target,
            .opcode = header.opcode,
            .descriptor = descriptor,
            .values = message.values,
        });

        if (!self.validateObjects(descriptor, &message)) {
            self.failProtocol(header.object_id, header.opcode, interface, "invalid object argument");
            return;
        }
        const expectations = self.collectNewIds(descriptor, &message) catch {
            self.record(.out_of_memory, header.object_id, header.opcode, interface, "collecting new ids");
            return;
        };
        defer self.allocator.free(expectations);
        const new_ids = self.allocator.alloc(u32, expectations.len) catch {
            self.record(.out_of_memory, header.object_id, header.opcode, interface, "collecting new ids");
            return;
        };
        defer self.allocator.free(new_ids);
        for (expectations, new_ids) |expectation, *id| id.* = expectation.id;
        self.objects.reserveClientIds(new_ids) catch |err| {
            const kind: Fatal.Kind = switch (err) {
                error.OutOfMemory, error.ObjectLimitReached => .out_of_memory,
                error.InvalidClientId, error.ClientIdGap, error.IdInUse, error.DuplicateId => .protocol,
            };
            self.record(kind, header.object_id, header.opcode, interface, "invalid or unavailable new id");
            return;
        };
        var rollback = true;
        defer if (rollback) self.objects.rollbackClientReservations(new_ids);

        const target_pointer: *anyopaque = target;
        const is_destructor = descriptor.destructor;
        self.active_new_ids = expectations;
        defer self.active_new_ids = null;
        target.dispatchErased(header.opcode, &message) catch |err| {
            self.record(if (err == error.OutOfMemory) .out_of_memory else .implementation, header.object_id, header.opcode, interface, "request handler failed");
            return;
        };
        // A handler may reject a request containing new_ids before creating
        // them. Preserve that first fatal and let the reservation defer undo
        // every ID that was not materialized.
        if (self.fatal_state.recorded) return;
        for (expectations) |expectation| if (expectation.state != .materialized) {
            self.record(.implementation, header.object_id, header.opcode, interface, "handler did not materialize new id");
            return;
        };
        if (is_destructor) {
            const current = self.objects.lookup(header.object_id);
            if (current != null and current.?.resource == target_pointer) {
                self.record(.implementation, header.object_id, header.opcode, interface, "destructor request did not destroy target");
                return;
            }
        }
        rollback = false;
    }
}

fn validateObjects(self: *Client, descriptor: *const wire.MessageDescriptor, message: *const wire.DecodedMessage) bool {
    for (descriptor.arguments, message.values) |argument, value| switch (argument.kind) {
        .object => |object_type| {
            const id = value.object orelse continue;
            const found = self.lookup(id) orelse return false;
            if (object_type.interface) |expected| if (!sameInterface(found.interface(), expected)) return false;
        },
        else => {},
    };
    return true;
}

fn collectNewIds(self: *Client, descriptor: *const wire.MessageDescriptor, message: *const wire.DecodedMessage) ![]NewIdExpectation {
    var count: usize = 0;
    for (message.values) |value| if (value == .new_id) {
        count += 1;
    };
    const ids = try self.allocator.alloc(NewIdExpectation, count);
    var index: usize = 0;
    for (descriptor.arguments, message.values) |argument, value| if (value == .new_id) {
        ids[index] = switch (value.new_id) {
            .typed => |id| .{ .id = id, .interface = argument.kind.new_id.?, .generic_name = null, .generic_version = null },
            .generic => |generic| .{ .id = generic.id, .interface = null, .generic_name = generic.interface, .generic_version = generic.version },
        };
        index += 1;
    };
    return ids;
}

fn retire(erased: *anyopaque, resource: *Resource) void {
    const self: *Client = @ptrCast(@alignCast(erased));
    const id = resource.id();
    const installed = self.objects.lookup(id);
    if (installed == null or installed.?.resource != @as(*anyopaque, @ptrCast(resource)) or installed.?.origin != resource.origin() or
        resource.state() != .destroying or !resource.ownedBy(self.ownerHooks()))
    {
        self.record(.implementation, id, null, resource.interface(), "retiring resource identity mismatch");
        return;
    }
    if (resource.origin() == .client) {
        self.output.enqueue(1, 1, &delete_id_descriptor, &.{.{ .uint = id }}) catch |err| {
            self.objects.discardLive(id, resource);
            self.record(if (err == error.OutOfMemory) .out_of_memory else .implementation, id, null, resource.interface(), "queueing delete_id");
            return;
        };
        if (self.lookup(1)) |display| self.logProtocol(.{
            .direction = .event,
            .resource = display,
            .opcode = 1,
            .descriptor = &delete_id_descriptor,
            .values = &.{.{ .uint = id }},
        });
        self.objects.retireClientAfterDeleteIdQueued(id, resource) catch {
            self.objects.discardLive(id, resource);
            self.record(.implementation, id, null, resource.interface(), "retiring client object");
        };
    } else self.objects.retireServer(id, resource) catch {
        self.objects.discardLive(id, resource);
        self.record(.implementation, id, null, resource.interface(), "retiring server object");
    };
}

fn sameInterface(a: *const wire.Interface, b: *const wire.Interface) bool {
    return a == b or std.mem.eql(u8, a.name, b.name);
}

fn emit(erased: *anyopaque, resource: *Resource, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
    const self: *Client = @ptrCast(@alignCast(erased));
    if (self.fatal_state.recorded) return error.ClientFatal;
    if (resource.state() != .live or !resource.ownedBy(self.ownerHooks())) return error.InvalidResourceIdentity;
    const installed = self.objects.lookup(resource.id()) orelse return error.InvalidResourceIdentity;
    if (installed.resource != @as(*anyopaque, @ptrCast(resource)) or installed.origin != resource.origin())
        return error.InvalidResourceIdentity;
    try self.output.enqueue(resource.id(), opcode, descriptor, values);
    self.logProtocol(.{
        .direction = .event,
        .resource = resource,
        .opcode = opcode,
        .descriptor = descriptor,
        .values = values,
    });
}

fn failMalformed(self: *Client, id: u32, opcode: ?u16, detail: []const u8) void {
    self.input.discardAfterFatal();
    self.record(.malformed_wire, id, opcode, null, detail);
}

fn failProtocol(self: *Client, id: u32, opcode: u16, interface: ?*const wire.Interface, detail: []const u8) void {
    self.input.discardAfterFatal();
    self.record(.protocol, id, opcode, interface, detail);
}

fn record(self: *Client, kind: Fatal.Kind, id: u32, opcode: ?u16, interface: ?*const wire.Interface, detail: []const u8) void {
    self.recordDetails(.{ .kind = kind, .object_id = id, .opcode = opcode, .interface = interface, .detail = detail });
}

fn recordDetails(self: *Client, details: Fatal.Details) void {
    self.input.discardAfterFatal();
    if (self.fatal_state.recorded or self.terminalizing) return;
    self.terminalizing = true;
    defer self.terminalizing = false;
    self.notifying_terminal = true;
    var observer = self.terminal_observer_head;
    while (observer) |current| {
        const next = current.next;
        if (current.active) current.notify(current.context, self, @ptrCast(current));
        observer = next;
    }
    self.notifying_terminal = false;
    if (!self.fatal_state.record(details)) return;
    if (details.kind == .peer_disconnect) return;
    const display = self.lookup(1) orelse return;
    if (!std.mem.eql(u8, display.interface().name, "wl_display")) return;

    const terminal_fatal = &self.fatal_state;
    const error_code: u32 = terminal_fatal.protocol_code orelse switch (terminal_fatal.kind) {
        .malformed_wire, .protocol => 1,
        .out_of_memory => 2,
        .implementation => 3,
        .peer_disconnect => return,
    };
    const string_len = terminal_fatal.detail().len + 1;
    const padded_len = std.mem.alignForward(usize, string_len, 4);
    const frame_len = 20 + padded_len;
    var frame: [wire.Output.terminal_capacity]u8 = @splat(0);
    std.mem.writeInt(u32, frame[0..4], 1, .native);
    std.mem.writeInt(u32, frame[4..8], (@as(u32, @intCast(frame_len)) << 16), .native);
    std.mem.writeInt(u32, frame[8..12], terminal_fatal.object_id, .native);
    std.mem.writeInt(u32, frame[12..16], error_code, .native);
    std.mem.writeInt(u32, frame[16..20], @intCast(string_len), .native);
    @memcpy(frame[20..][0..terminal_fatal.detail().len], terminal_fatal.detail());
    self.output.sealWithTerminal(frame[0..frame_len]) catch unreachable;
    self.logProtocol(.{
        .direction = .event,
        .resource = display,
        .opcode = 0,
        .descriptor = &display_error_descriptor,
        .values = &.{
            .{ .object = terminal_fatal.object_id },
            .{ .uint = error_code },
            .{ .string = terminal_fatal.detail() },
        },
    });
}

fn logProtocol(self: *Client, message: ProtocolMessage) void {
    const sink = self.protocol_log_sink orelse return;
    sink.notify(sink.context, self, message);
}

fn unlinkAndFreeObserver(self: *Client, observer: *ObserverNode) void {
    if (observer.previous) |previous| previous.next = observer.next else self.observer_head = observer.next;
    if (observer.next) |next| next.previous = observer.previous else self.observer_tail = observer.previous;
    self.allocator.destroy(observer);
}

fn unlinkAndFreeTerminalObserver(self: *Client, observer: *TerminalObserverNode) void {
    if (observer.previous) |previous| previous.next = observer.next else self.terminal_observer_head = observer.next;
    if (observer.next) |next| next.previous = observer.previous else self.terminal_observer_tail = observer.previous;
    self.allocator.destroy(observer);
}

fn freeAllObservers(self: *Client) void {
    var current = self.observer_head;
    while (current) |observer| {
        const next = observer.next;
        self.allocator.destroy(observer);
        current = next;
    }
    self.observer_head = null;
    self.observer_tail = null;
    var terminal = self.terminal_observer_head;
    while (terminal) |observer| {
        const next = observer.next;
        self.allocator.destroy(observer);
        terminal = next;
    }
    self.terminal_observer_head = null;
    self.terminal_observer_tail = null;
}

test "Client destruction observers retain order and can remove registrations" {
    const Context = struct {
        order: *std.ArrayList(u8),
        future: ?*Observer = null,
        label: u8,

        fn observe(self: *@This(), client: *Client, handle: *Observer) void {
            self.order.append(std.testing.allocator, self.label) catch unreachable;
            std.testing.expectError(error.ClientDestroying, client.addDestroyObserver(@This(), self, observe)) catch unreachable;
            if (self.label == 'a') {
                removeDestroyObserver(handle);
                removeDestroyObserver(self.future.?);
                client.deinit();
            }
        }
    };

    var client: Client = .init(std.testing.allocator, .{});
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.testing.allocator);
    var first: Context = .{ .order = &order, .label = 'a' };
    var second: Context = .{ .order = &order, .label = 'b' };
    var third: Context = .{ .order = &order, .label = 'c' };
    var removed: Context = .{ .order = &order, .label = 'x' };
    _ = try client.addDestroyObserver(Context, &first, Context.observe);
    _ = try client.addDestroyObserver(Context, &second, Context.observe);
    first.future = try client.addDestroyObserver(Context, &third, Context.observe);
    const removed_handle = try client.addDestroyObserver(Context, &removed, Context.observe);
    removeDestroyObserver(removed_handle);

    client.deinit();
    try std.testing.expectEqualStrings("ab", order.items);
}

test "terminal observers run once before the first fatal is visible" {
    const Context = struct {
        calls: usize = 0,
        fatal_was_visible: bool = false,
        future: ?*TerminalObserver = null,

        fn observe(self: *@This(), client: *Client, handle: *TerminalObserver) void {
            self.calls += 1;
            self.fatal_was_visible = self.fatal_was_visible or client.fatal() != null;
            std.testing.expectError(
                error.ClientTerminal,
                client.addTerminalObserver(@This(), self, observe),
            ) catch unreachable;
            removeTerminalObserver(handle);
            if (self.future) |future| removeTerminalObserver(future);
            client.postImplementationError(client.lookup(1).?, "reentrant fatal");
        }
    };

    var client: Client = .init(std.testing.allocator, .{});
    defer client.deinit();
    var display: Resource = .init(std.testing.allocator, 1, 1, &test_display_interface, &.{}, .client, client.ownerHooks());
    defer {
        display.destroy();
        display.deinit();
    }
    try client.installClientInitial(1, &display);
    var first: Context = .{};
    var removed: Context = .{};
    _ = try client.addTerminalObserver(Context, &first, Context.observe);
    first.future = try client.addTerminalObserver(Context, &removed, Context.observe);

    client.postOutOfMemory(&display, "first fatal");
    try std.testing.expectEqual(@as(usize, 1), first.calls);
    try std.testing.expectEqual(@as(usize, 0), removed.calls);
    try std.testing.expect(!first.fatal_was_visible);
    try std.testing.expectEqual(Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expectEqualStrings("first fatal", client.fatal().?.detail());
    client.postProtocolError(&display, 9, "later fatal");
    try std.testing.expectEqual(@as(usize, 1), first.calls);
}

test "Client fatal terminal frames are allocation independent and follow in-flight output" {
    comptime {
        std.debug.assert(wire.Output.terminal_capacity >= 20 + std.mem.alignForward(usize, Fatal.max_detail_len + 1, 4));
    }
    const event: wire.MessageDescriptor = .{ .name = "ordinary", .arguments = &.{} };
    const Case = struct {
        kind: Fatal.Kind,
        explicit_code: ?u32 = null,
        expected_code: u32,
        detail: []const u8,

        fn run(case: @This()) !void {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var client: Client = .init(failing.allocator(), .{});
            var display: Resource = .init(failing.allocator(), 1, 1, &test_display_interface, &.{}, .client, client.ownerHooks());
            try client.installClientInitial(1, &display);
            try display.emit(7, &event, &.{});
            const ordinary = (try client.beginSend()).?;

            failing.fail_index = failing.alloc_index;
            if (case.explicit_code) |code|
                client.postProtocolError(&display, code, case.detail)
            else
                client.record(case.kind, 41, 6, null, case.detail);

            const recorded_fatal = client.fatal().?;
            try std.testing.expectEqual(case.kind, recorded_fatal.kind);
            try std.testing.expectEqualSlices(u8, case.detail, recorded_fatal.detail());
            client.record(.implementation, 99, 9, null, "competing later fatal");
            try std.testing.expectEqual(case.kind, client.fatal().?.kind);
            try std.testing.expectEqualSlices(u8, case.detail, client.fatal().?.detail());

            try client.completeSend(ordinary.token, 1);
            const remainder = (try client.beginSend()).?;
            try std.testing.expectEqual(@as(usize, 0), remainder.fds.len);
            try client.completeSend(remainder.token, remainder.bytes.len);
            const terminal = (try client.beginSend()).?;
            const expected_id: u32 = if (case.explicit_code != null) 1 else 41;
            const string_len = case.detail.len + 1;
            const expected_len = 20 + std.mem.alignForward(usize, string_len, 4);
            try std.testing.expectEqual(expected_len, terminal.bytes.len);
            try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, terminal.bytes[0..4], .native));
            const size_opcode = std.mem.readInt(u32, terminal.bytes[4..8], .native);
            try std.testing.expectEqual(@as(u16, 0), @as(u16, @truncate(size_opcode)));
            try std.testing.expectEqual(@as(u16, @intCast(expected_len)), @as(u16, @truncate(size_opcode >> 16)));
            try std.testing.expectEqual(expected_id, std.mem.readInt(u32, terminal.bytes[8..12], .native));
            try std.testing.expectEqual(case.expected_code, std.mem.readInt(u32, terminal.bytes[12..16], .native));
            try std.testing.expectEqual(@as(u32, @intCast(string_len)), std.mem.readInt(u32, terminal.bytes[16..20], .native));
            try std.testing.expectEqualSlices(u8, case.detail, terminal.bytes[20 .. 20 + case.detail.len]);
            try std.testing.expectEqual(@as(u8, 0), terminal.bytes[20 + case.detail.len]);
            for (terminal.bytes[20 + string_len ..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
            try std.testing.expectEqual(@as(usize, 0), terminal.fds.len);
            try client.completeSend(terminal.token, terminal.bytes.len);
            try std.testing.expect((try client.beginSend()) == null);
            display.destroy();
            display.deinit();
            client.deinit();
            try std.testing.expect(!failing.has_induced_failure);
        }
    };

    inline for ([_]Case{
        .{ .kind = .malformed_wire, .expected_code = 1, .detail = "malformed" },
        .{ .kind = .protocol, .expected_code = 1, .detail = "protocol default" },
        .{ .kind = .protocol, .explicit_code = 0, .expected_code = 0, .detail = "protocol zero" },
        .{ .kind = .protocol, .explicit_code = 73, .expected_code = 73, .detail = "protocol exact" },
        .{ .kind = .out_of_memory, .expected_code = 2, .detail = "oom" },
        .{ .kind = .implementation, .expected_code = 3, .detail = "implementation" },
    }) |case| try case.run();
}

test "Client fatal without display records but has no terminal output" {
    var client: Client = .init(std.testing.allocator, .{});
    defer client.deinit();
    client.record(.implementation, 4, null, null, "no display");
    try std.testing.expectEqual(Fatal.Kind.implementation, client.fatal().?.kind);
    try std.testing.expect((try client.beginSend()) == null);
}

test "transport fatal entry points allocate nothing and disconnect emits no terminal output" {
    inline for (.{
        .{ .kind = Fatal.Kind.malformed_wire, .call = Client.transportMalformed },
        .{ .kind = Fatal.Kind.out_of_memory, .call = Client.transportOutOfMemory },
        .{ .kind = Fatal.Kind.peer_disconnect, .call = Client.peerDisconnected },
    }) |case| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var client: Client = .init(failing.allocator(), .{});
        var display: Resource = .init(failing.allocator(), 1, 1, &test_display_interface, &.{}, .client, client.ownerHooks());
        try client.installClientInitial(1, &display);
        failing.fail_index = failing.alloc_index;
        case.call(&client);
        try std.testing.expectEqual(case.kind, client.fatal().?.kind);
        try std.testing.expect(!failing.has_induced_failure);
        failing.fail_index = std.math.maxInt(usize);
        if (case.kind == .peer_disconnect)
            try std.testing.expect((try client.beginSend()) == null)
        else {
            const terminal = (try client.beginSend()).?;
            try client.completeSend(terminal.token, terminal.bytes.len);
        }
        display.destroy();
        display.deinit();
        client.deinit();
    }
}

test "fragmented frames dispatch twice and recursive client dispatch is rejected" {
    const interface: wire.Interface = .{ .name = "wl_display", .version = 1 };
    const request: wire.MessageDescriptor = .{ .name = "sync", .arguments = &.{} };
    const Context = struct {
        client: *Client,
        calls: usize = 0,

        fn handle(context: *@This(), _: *Resource, _: u16, _: *wire.DecodedMessage) !void {
            context.calls += 1;
            try std.testing.expectError(error.DispatchInProgress, context.client.dispatch());
        }
    };

    var client: Client = .init(std.testing.allocator, .{});
    defer client.deinit();
    var resource: Resource = .init(std.testing.allocator, 1, 1, &interface, &.{request}, .client, client.ownerHooks());
    var context: Context = .{ .client = &client };
    try resource.setHandler(Context, &context, Context.handle, null);
    try client.installClientInitial(1, &resource);

    var encoder: wire.Output = .init(std.testing.allocator);
    defer encoder.deinit();
    try encoder.enqueue(1, 0, &request, &.{});
    try encoder.enqueue(1, 0, &request, &.{});
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    while (try encoder.beginSend()) |batch| {
        try bytes.appendSlice(std.testing.allocator, batch.bytes);
        try encoder.completeSend(batch.token, batch.bytes.len);
    }
    try client.receive(bytes.items[0..5], &.{});
    try client.dispatch();
    try std.testing.expectEqual(@as(usize, 0), context.calls);
    try client.receive(bytes.items[5..], &.{});
    try client.dispatch();
    try std.testing.expectEqual(@as(usize, 2), context.calls);
    try std.testing.expect(client.fatal() == null);
}

fn testFrame(descriptor: *const wire.MessageDescriptor, object_id: u32, values: []const wire.Value) ![]u8 {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, 0, descriptor, values);
    const batch = (try output.beginSend()).?;
    const bytes = try std.testing.allocator.dupe(u8, batch.bytes);
    try output.completeSend(batch.token, batch.bytes.len);
    return bytes;
}

fn testDispatch(client: *Client, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
    const bytes = try testFrame(descriptor, 1, values);
    defer std.testing.allocator.free(bytes);
    try client.receive(bytes, &.{});
    try client.dispatch();
}

const test_display_interface: wire.Interface = .{ .name = "wl_display", .version = 1 };
const test_child_interface: wire.Interface = .{ .name = "wl_child", .version = 3 };

test "Client object arguments validate identity by interface name before handler" {
    const same_name: wire.Interface = .{ .name = "wl_child", .version = 1 };
    const wrong: wire.Interface = .{ .name = "wl_wrong", .version = 1 };
    const request: wire.MessageDescriptor = .{ .name = "use", .arguments = &.{.{ .name = "object", .kind = .{ .object = .{ .interface = &test_child_interface, .nullability = .nullable } } }} };
    const Context = struct {
        calls: usize = 0,
        fn handle(self: *@This(), _: *Resource, _: u16, _: *wire.DecodedMessage) !void {
            self.calls += 1;
        }
    };
    const Case = struct {
        fn run(interface: ?*const wire.Interface, id: ?u32, succeeds: bool) !void {
            var client: Client = .init(std.testing.allocator, .{});
            defer client.deinit();
            var target: Resource = .init(std.testing.allocator, 1, 1, &test_display_interface, &.{request}, .client, client.ownerHooks());
            var context: Context = .{};
            try target.setHandler(Context, &context, Context.handle, null);
            try client.installClientInitial(1, &target);
            var argument: ?Resource = null;
            if (interface) |value| {
                argument = .init(std.testing.allocator, 2, 1, value, &.{}, .client, client.ownerHooks());
                try client.installClientInitial(2, &argument.?);
            }
            try testDispatch(&client, &request, &.{.{ .object = id }});
            try std.testing.expectEqual(@as(usize, if (succeeds) 1 else 0), context.calls);
            if (succeeds) try std.testing.expect(client.fatal() == null) else try std.testing.expectEqual(Fatal.Kind.protocol, client.fatal().?.kind);
        }
    };
    try Case.run(null, 77, false);
    try Case.run(&wrong, 2, false);
    try Case.run(&same_name, 2, true);
    try Case.run(null, null, true);
}

test "Client typed and generic new ids materialize atomically and reject invalid reservations" {
    const request: wire.MessageDescriptor = .{ .name = "create", .arguments = &.{
        .{ .name = "typed", .kind = .{ .new_id = &test_child_interface } },
        .{ .name = "generic", .kind = .{ .new_id = null } },
    } };
    const Context = struct {
        client: *Client,
        mode: enum { good, wrong_typed, wrong_name, wrong_version, missing },
        calls: usize = 0,
        first: ?Resource = null,
        second: ?Resource = null,
        fn handle(self: *@This(), _: *Resource, _: u16, message: *wire.DecodedMessage) !void {
            self.calls += 1;
            const first_id = message.values[0].new_id.typed;
            const generic = message.values[1].new_id.generic;
            const first_interface = if (self.mode == .wrong_typed) &test_display_interface else &test_child_interface;
            self.first = .init(std.testing.allocator, first_id, 1, first_interface, &.{}, .client, self.client.ownerHooks());
            try self.client.materialize(&self.first.?);
            if (self.mode == .missing) return;
            const second_interface = switch (self.mode) {
                .wrong_name => &test_display_interface,
                else => &test_child_interface,
            };
            const version: u32 = if (self.mode == .wrong_version or self.mode == .wrong_name) 1 else generic.version;
            self.second = .init(std.testing.allocator, generic.id, version, second_interface, &.{}, .client, self.client.ownerHooks());
            try self.client.materialize(&self.second.?);
        }
    };
    const Case = struct {
        fn run(mode: @FieldType(Context, "mode"), generic_name: []const u8, generic_version: u32, expect_success: bool) !void {
            var client: Client = .init(std.testing.allocator, .{});
            defer client.deinit();
            var target: Resource = .init(std.testing.allocator, 1, 1, &test_display_interface, &.{request}, .client, client.ownerHooks());
            var context: Context = .{ .client = &client, .mode = mode };
            try target.setHandler(Context, &context, Context.handle, null);
            try client.installClientInitial(1, &target);
            try testDispatch(&client, &request, &.{
                .{ .new_id = .{ .typed = 2 } },
                .{ .new_id = .{ .generic = .{ .interface = generic_name, .version = generic_version, .id = 3 } } },
            });
            try std.testing.expectEqual(@as(usize, 1), context.calls);
            if (expect_success) {
                try std.testing.expectEqual(&context.first.?, client.lookup(2).?);
                try std.testing.expectEqual(&context.second.?, client.lookup(3).?);
                try std.testing.expect(client.fatal() == null);
            } else {
                try std.testing.expectEqual(Fatal.Kind.implementation, client.fatal().?.kind);
                if (mode == .missing) try std.testing.expect(client.lookup(3) == null);
            }
        }
    };
    try Case.run(.good, "wl_child", 2, true);
    try Case.run(.wrong_typed, "wl_child", 2, false);
    try Case.run(.wrong_name, "wl_child", 2, false);
    try Case.run(.wrong_version, "wl_child", 2, false);
    try Case.run(.missing, "wl_child", 2, false);

    const ReservationCase = struct {
        fn run(ids: [2]u32, expected: Fatal.Kind) !void {
            var client: Client = .init(std.testing.allocator, .{});
            defer client.deinit();
            var target: Resource = .init(std.testing.allocator, 1, 1, &test_display_interface, &.{request}, .client, client.ownerHooks());
            var context: Context = .{ .client = &client, .mode = .good };
            try target.setHandler(Context, &context, Context.handle, null);
            try client.installClientInitial(1, &target);
            try testDispatch(&client, &request, &.{ .{ .new_id = .{ .typed = ids[0] } }, .{ .new_id = .{ .generic = .{ .interface = "wl_child", .version = 2, .id = ids[1] } } } });
            try std.testing.expectEqual(@as(usize, 0), context.calls);
            try std.testing.expectEqual(expected, client.fatal().?.kind);
        }
    };
    try ReservationCase.run(.{ 2, 2 }, .protocol);
    try ReservationCase.run(.{ 1, 2 }, .protocol);
    try ReservationCase.run(.{ 2, 4 }, .protocol);
}

test "Client preserves handler protocol fatal and rolls back unmaterialized new id" {
    const request: wire.MessageDescriptor = .{ .name = "reject", .arguments = &.{.{ .name = "id", .kind = .{ .new_id = &test_child_interface } }} };
    const Context = struct {
        client: *Client,

        fn handle(self: *@This(), resource: *Resource, _: u16, _: *wire.DecodedMessage) !void {
            self.client.postProtocolError(resource, 73, "chosen rejection");
        }
    };

    var client: Client = .init(std.testing.allocator, .{});
    defer client.deinit();
    var target: Resource = .init(std.testing.allocator, 1, 1, &test_display_interface, &.{request}, .client, client.ownerHooks());
    defer {
        target.destroy();
        target.deinit();
    }
    var context: Context = .{ .client = &client };
    try target.setHandler(Context, &context, Context.handle, null);
    try client.installClientInitial(1, &target);

    try testDispatch(&client, &request, &.{.{ .new_id = .{ .typed = 2 } }});
    const recorded_fatal = client.fatal().?;
    try std.testing.expectEqual(Fatal.Kind.protocol, recorded_fatal.kind);
    try std.testing.expectEqual(@as(?u32, 73), recorded_fatal.protocol_code);
    try std.testing.expect(client.lookup(2) == null);
}

test "Client destructor orders delete_id retires once and permits reuse" {
    const event: wire.MessageDescriptor = .{ .name = "notice", .arguments = &.{.{ .name = "value", .kind = .uint }} };
    const destroy_request: wire.MessageDescriptor = .{ .name = "destroy", .destructor = true, .arguments = &.{} };
    const create_request: wire.MessageDescriptor = .{ .name = "create", .arguments = &.{.{ .name = "id", .kind = .{ .new_id = &test_child_interface } }} };
    const Context = struct {
        fn handle(_: *@This(), resource: *Resource, _: u16, _: *wire.DecodedMessage) !void {
            resource.destroy();
        }
    };
    const CreateContext = struct {
        client: *Client,
        created: ?Resource = null,
        fn handle(self: *@This(), _: *Resource, _: u16, message: *wire.DecodedMessage) !void {
            self.created = .init(std.testing.allocator, message.values[0].new_id.typed, 1, &test_child_interface, &.{}, .client, self.client.ownerHooks());
            try self.client.materialize(&self.created.?);
        }
    };
    var client: Client = .init(std.testing.allocator, .{});
    defer client.deinit();
    var target: Resource = .init(std.testing.allocator, 1, 1, &test_display_interface, &.{create_request}, .client, client.ownerHooks());
    var child: Resource = .init(std.testing.allocator, 2, 1, &test_child_interface, &.{destroy_request}, .client, client.ownerHooks());
    var context: Context = .{};
    var create_context: CreateContext = .{ .client = &client };
    try target.setHandler(CreateContext, &create_context, CreateContext.handle, null);
    try child.setHandler(Context, &context, Context.handle, null);
    try client.installClientInitial(1, &target);
    try client.installClientInitial(2, &child);
    try target.emit(7, &event, &.{.{ .uint = 9 }});
    const frame = try testFrame(&destroy_request, 2, &.{});
    defer std.testing.allocator.free(frame);
    try client.receive(frame, &.{});
    try client.dispatch();
    try std.testing.expect(client.lookup(2) == null);
    child.destroy();
    const first = (try client.beginSend()).?;
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, first.bytes[0..4], @import("builtin").cpu.arch.endian()));
    try std.testing.expectEqual(@as(u16, 7), @as(u16, @truncate(std.mem.readInt(u32, first.bytes[4..8], @import("builtin").cpu.arch.endian()))));
    try std.testing.expectEqual(@as(usize, 24), first.bytes.len);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, first.bytes[12..16], @import("builtin").cpu.arch.endian()));
    try std.testing.expectEqual(@as(u16, 1), @as(u16, @truncate(std.mem.readInt(u32, first.bytes[16..20], @import("builtin").cpu.arch.endian()))));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, first.bytes[20..24], @import("builtin").cpu.arch.endian()));
    try client.completeSend(first.token, first.bytes.len);
    try std.testing.expect((try client.beginSend()) == null);
    try testDispatch(&client, &create_request, &.{.{ .new_id = .{ .typed = 2 } }});
    try std.testing.expectEqual(&create_context.created.?, client.lookup(2).?);
    child.deinit();
}

test "Client destructor handler must destroy its target" {
    const request: wire.MessageDescriptor = .{ .name = "destroy", .destructor = true, .arguments = &.{} };
    const Context = struct {
        fn handle(_: *@This(), _: *Resource, _: u16, _: *wire.DecodedMessage) !void {}
    };
    var client: Client = .init(std.testing.allocator, .{});
    defer client.deinit();
    var target: Resource = .init(std.testing.allocator, 1, 1, &test_display_interface, &.{request}, .client, client.ownerHooks());
    var context: Context = .{};
    try target.setHandler(Context, &context, Context.handle, null);
    try client.installClientInitial(1, &target);
    try testDispatch(&client, &request, &.{});
    try std.testing.expectEqual(Fatal.Kind.implementation, client.fatal().?.kind);
    try std.testing.expectEqual(&target, client.lookup(1).?);
}

test "Client retirement and emit require exact installed resource identity" {
    const event: wire.MessageDescriptor = .{ .name = "event", .arguments = &.{} };
    var client: Client = .init(std.testing.allocator, .{});
    defer client.deinit();
    var installed: Resource = .init(std.testing.allocator, 1, 1, &test_display_interface, &.{}, .client, client.ownerHooks());
    try client.installClientInitial(1, &installed);
    var impostor: Resource = .init(std.testing.allocator, 1, 1, &test_display_interface, &.{}, .client, client.ownerHooks());
    try std.testing.expectError(error.InvalidResourceIdentity, impostor.emit(0, &event, &.{}));
    try std.testing.expect((try client.beginSend()) == null);
    impostor.destroy();
    try std.testing.expectEqual(Fatal.Kind.implementation, client.fatal().?.kind);
    try std.testing.expectEqual(&installed, client.lookup(1).?);
    const terminal = (try client.beginSend()).?;
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, terminal.bytes[0..4], .native));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, terminal.bytes[12..16], .native));
    try client.completeSend(terminal.token, terminal.bytes.len);
    impostor.deinit();
}

test "Client prepared events log only after the complete sequence is published" {
    const event_arguments = [_]wire.ArgumentDescriptor{.{ .name = "value", .kind = .uint }};
    const first_event: wire.MessageDescriptor = .{ .name = "first", .arguments = &event_arguments };
    const second_event: wire.MessageDescriptor = .{ .name = "second", .arguments = &event_arguments };
    const Log = struct {
        count: usize = 0,
        opcodes: [2]u16 = undefined,

        fn notify(context: *anyopaque, _: *Client, message: ProtocolMessage) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.opcodes[self.count] = message.opcode;
            self.count += 1;
        }
    };
    var log: Log = .{};
    var client: Client = .init(std.testing.allocator, .{ .protocol_log_sink = .{
        .context = &log,
        .notify = Log.notify,
    } });
    defer client.deinit();
    var resource: Resource = .init(std.testing.allocator, 1, 1, &test_display_interface, &.{}, .client, client.ownerHooks());
    try client.installClientInitial(1, &resource);
    const events = [_]PreparedEvent{
        .{ .resource = &resource, .opcode = 3, .descriptor = &first_event, .values = &.{.{ .uint = 11 }} },
        .{ .resource = &resource, .opcode = 4, .descriptor = &second_event, .values = &.{.{ .uint = 12 }} },
    };

    const too_small = try client.prepareEvents(12);
    try std.testing.expectError(error.WriteFailed, client.emitPreparedEvents(too_small, &events));
    try std.testing.expectEqual(@as(usize, 0), log.count);
    try std.testing.expect((try client.beginSend()) == null);
    client.cancelPreparedEvents(too_small);

    const prepared = try client.prepareEvents(24);
    try client.emitPreparedEvents(prepared, &events);
    try std.testing.expectEqual(@as(usize, 2), log.count);
    try std.testing.expectEqualSlices(u16, &.{ 3, 4 }, &log.opcodes);
    const batch = (try client.beginSend()).?;
    try std.testing.expectEqual(@as(usize, 24), batch.bytes.len);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, batch.bytes[0..4], .native));
    try std.testing.expectEqual(@as(u16, 3), @as(u16, @truncate(std.mem.readInt(u32, batch.bytes[4..8], .native))));
    try std.testing.expectEqual(@as(u16, 4), @as(u16, @truncate(std.mem.readInt(u32, batch.bytes[16..20], .native))));
    try client.completeSend(batch.token, batch.bytes.len);
}

test "Client server lifecycle reuses ids without delete_id and rejects impostor retirement" {
    var client: Client = .init(std.testing.allocator, .{});
    defer client.deinit();
    const rolled_back = try client.reserveServerId();
    client.rollbackServerId(rolled_back);
    try std.testing.expectEqual(rolled_back, try client.reserveServerId());
    var resource: Resource = .init(std.testing.allocator, rolled_back, 1, &test_child_interface, &.{}, .server, client.ownerHooks());
    try client.materializeServer(&resource);
    var impostor: Resource = .init(std.testing.allocator, rolled_back, 1, &test_child_interface, &.{}, .server, client.ownerHooks());
    impostor.destroy();
    try std.testing.expectEqual(&resource, client.lookup(rolled_back).?);
    impostor.deinit();
    resource.destroy();
    resource.deinit();
    try std.testing.expectEqual(rolled_back, try client.reserveServerId());
    try std.testing.expect((try client.beginSend()) == null);
}

test "Client fatal classification closes pending fd and first fatal wins" {
    var pipe_fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&pipe_fds));
    defer _ = std.c.close(pipe_fds[1]);
    var client: Client = .init(std.testing.allocator, .{});
    defer client.deinit();
    const unknown: wire.MessageDescriptor = .{ .name = "unknown", .arguments = &.{} };
    const bytes = try testFrame(&unknown, 99, &.{});
    defer std.testing.allocator.free(bytes);
    try client.receive(bytes, &.{pipe_fds[0]});
    try client.dispatch();
    try std.testing.expectEqual(Fatal.Kind.protocol, client.fatal().?.kind);
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(pipe_fds[0], std.c.F.GETFD));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(std.c.E.BADF)), std.c._errno().*);
    client.record(.out_of_memory, 1, 0, null, "later");
    try std.testing.expectEqual(Fatal.Kind.protocol, client.fatal().?.kind);

    const ErrorCase = struct {
        fn run(handler_error: anyerror, expected: Fatal.Kind) !void {
            const request: wire.MessageDescriptor = .{ .name = "fail", .arguments = &.{} };
            const Context = struct {
                value: anyerror,
                fn handle(self: *@This(), _: *Resource, _: u16, _: *wire.DecodedMessage) !void {
                    return self.value;
                }
            };
            var item: Client = .init(std.testing.allocator, .{});
            defer item.deinit();
            var target: Resource = .init(std.testing.allocator, 1, 1, &test_display_interface, &.{request}, .client, item.ownerHooks());
            var context: Context = .{ .value = handler_error };
            try target.setHandler(Context, &context, Context.handle, null);
            try item.installClientInitial(1, &target);
            try testDispatch(&item, &request, &.{});
            try std.testing.expectEqual(expected, item.fatal().?.kind);
        }
    };
    try ErrorCase.run(error.OutOfMemory, .out_of_memory);
    try ErrorCase.run(error.BrokenHandler, .implementation);
}

test "Client object limit is out of memory and dense gap is protocol" {
    const request: wire.MessageDescriptor = .{ .name = "create", .arguments = &.{.{ .name = "id", .kind = .{ .new_id = &test_child_interface } }} };
    const Context = struct {
        calls: usize = 0,
        fn handle(self: *@This(), _: *Resource, _: u16, _: *wire.DecodedMessage) !void {
            self.calls += 1;
        }
    };
    const Case = struct {
        fn run(max_objects: usize, id: u32, expected: Fatal.Kind) !void {
            var client: Client = .init(std.testing.allocator, .{ .max_objects = max_objects });
            defer client.deinit();
            var target: Resource = .init(std.testing.allocator, 1, 1, &test_display_interface, &.{request}, .client, client.ownerHooks());
            var context: Context = .{};
            try target.setHandler(Context, &context, Context.handle, null);
            try client.installClientInitial(1, &target);
            try testDispatch(&client, &request, &.{.{ .new_id = .{ .typed = id } }});
            try std.testing.expectEqual(@as(usize, 0), context.calls);
            try std.testing.expectEqual(expected, client.fatal().?.kind);
        }
    };
    try Case.run(1, 2, .out_of_memory);
    try Case.run(4, 3, .protocol);
}
