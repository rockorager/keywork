const std = @import("std");
const generated = @import("generated");
const wayring = @import("wayring");

const Fixture = generated.@"test-object";
const EmptyFixture = generated.other;

const Owner = struct {
    output: wayring.wire.Output,
    order: std.ArrayList(u8) = .empty,
    emitted: usize = 0,

    fn init() Owner {
        return .{ .output = .init(std.testing.allocator) };
    }

    fn deinit(self: *Owner) void {
        self.output.deinit();
        self.order.deinit(std.testing.allocator);
    }

    fn retire(erased: *anyopaque, resource: *wayring.server.Resource) void {
        const self: *Owner = @ptrCast(@alignCast(erased));
        std.debug.assert(resource.state() == .destroying);
        self.order.append(std.testing.allocator, 'r') catch unreachable;
    }

    fn emit(erased: *anyopaque, resource: *wayring.server.Resource, opcode: u16, descriptor: *const wayring.wire.MessageDescriptor, values: []const wayring.wire.Value) !void {
        const self: *Owner = @ptrCast(@alignCast(erased));
        self.emitted += 1;
        try self.output.enqueue(resource.id(), opcode, descriptor, values);
    }

    fn hooks(self: *Owner) wayring.server.Resource.OwnerHooks {
        return .{ .context = self, .retire = Owner.retire, .emit = Owner.emit };
    }
};

const HandlerContext = struct {
    expected_resource: *Fixture.Resource,
    called: usize = 0,
    destroyed: usize = 0,
    owned_fd: ?std.posix.fd_t = null,

    fn handle(resource: *Fixture.Resource, request: Fixture.Request, self: *@This()) !void {
        try std.testing.expectEqual(self.expected_resource, resource);
        try std.testing.expectEqual(@as(u32, 31), resource.id());
        const destroy_request = request.destroy;
        try std.testing.expectEqualStrings("valid", destroy_request.label.?);
        try std.testing.expectEqual(@as(u32, 9), destroy_request.serial);
        self.owned_fd = destroy_request.descriptor;
        self.called += 1;
    }

    fn destroy(resource: *Fixture.Resource, self: *@This()) void {
        std.debug.assert(resource.id() == 31);
        std.debug.assert(resource.state() == .destroying);
        self.destroyed += 1;
    }
};

const SelfDestroyTrace = struct {
    order: std.ArrayList(u8) = .empty,
    destructor_count: usize = 0,
    metadata_valid: bool = false,
};

const SelfDestroyContext = struct {
    trace: *SelfDestroyTrace,

    fn handle(resource: *Fixture.Resource, request: Fixture.Request, self: *@This()) !void {
        _ = std.c.close(request.destroy.descriptor);
        const trace = self.trace;
        try trace.order.append(std.testing.allocator, 'h');
        resource.destroy();
    }

    fn destroy(resource: *Fixture.Resource, self: *@This()) void {
        self.trace.destructor_count += 1;
        self.trace.metadata_valid = resource.id() == 41 and resource.version() == 2 and resource.interface() == &Fixture.interface and resource.state() == .destroying;
        self.trace.order.append(std.testing.allocator, 'd') catch unreachable;
    }
};

const ObserverContext = struct {
    trace: *SelfDestroyTrace,

    fn observe(self: *@This(), resource: *wayring.server.Resource, _: *wayring.server.Resource.Observer) void {
        self.trace.metadata_valid = resource.id() == 41 and resource.interface() == &Fixture.interface and resource.state() == .destroying;
        self.trace.order.append(std.testing.allocator, 'o') catch unreachable;
    }
};

fn decoded(fd: std.posix.fd_t, label: ?[]const u8, serial: u32) !wayring.wire.DecodedMessage {
    return .{
        .allocator = std.testing.allocator,
        .descriptor = &Fixture.request_messages[0],
        .body = try std.testing.allocator.alloc(u8, 0),
        .values = try std.testing.allocator.dupe(wayring.wire.Value, &.{
            .{ .string = label },
            .{ .object = null },
            .{ .new_id = .{ .generic = .{ .interface = "other", .version = 2, .id = 4 } } },
            .{ .new_id = .{ .typed = 5 } },
            .{ .uint = 1 },
            .{ .array = "bytes" },
            .{ .fd = fd },
            .{ .uint = serial },
        }),
    };
}

test "generated typed resource dispatches requests and emits events through owner hooks" {
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer _ = std.c.close(pipe_fds[1]);

    var message = try decoded(pipe_fds[0], null, 9);
    defer message.deinit();
    message.values[7] = .{ .int = 9 };
    try std.testing.expectError(error.InvalidRequestValue, Fixture.decodeRequest(0, &message));
    try std.testing.expectEqual(pipe_fds[0], message.values[6].fd.?);
    message.values[0] = .{ .string = "valid" };
    message.values[7] = .{ .uint = 9 };

    var owner = Owner.init();
    defer owner.deinit();
    var resource = Fixture.Resource.init(std.testing.allocator, 31, 2, .client, owner.hooks());
    var context: HandlerContext = .{ .expected_resource = &resource };
    try resource.setHandler(HandlerContext, &context, HandlerContext.handle, HandlerContext.destroy);
    try resource.runtime.dispatchErased(0, &message);
    try std.testing.expectEqual(@as(usize, 1), context.called);
    try std.testing.expect(message.values[6].fd == null);
    defer if (context.owned_fd) |fd| {
        _ = std.c.close(fd);
    };

    try Fixture.@"send:done"(&resource, 7, 8, "done", "data", pipe_fds[1]);
    try std.testing.expectEqual(@as(usize, 1), owner.emitted);
    try std.testing.expect((try owner.output.beginSend()) != null);

    resource.destroy();
    try std.testing.expectEqual(@as(usize, 1), context.destroyed);
    resource.deinit();
}

test "generated typed handler may destroy itself with ordered valid callbacks" {
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Unexpected;
    defer _ = std.c.close(pipe_fds[1]);
    var message = try decoded(pipe_fds[0], "self", 12);
    defer message.deinit();

    var owner = Owner.init();
    defer owner.deinit();
    var resource = Fixture.Resource.init(std.testing.allocator, 41, 2, .server, owner.hooks());
    var trace: SelfDestroyTrace = .{};
    defer trace.order.deinit(std.testing.allocator);
    var context: SelfDestroyContext = .{ .trace = &trace };
    var observer: ObserverContext = .{ .trace = &trace };
    _ = try resource.runtime.addDestroyObserver(ObserverContext, &observer, ObserverContext.observe);
    try resource.setHandler(SelfDestroyContext, &context, SelfDestroyContext.handle, SelfDestroyContext.destroy);
    try resource.runtime.dispatchErased(0, &message);

    try std.testing.expectEqualStrings("hod", trace.order.items);
    try std.testing.expectEqualStrings("r", owner.order.items);
    try std.testing.expect(trace.metadata_valid);
    try std.testing.expectEqual(@as(usize, 1), trace.destructor_count);
    resource.destroy();
    try std.testing.expectEqual(@as(usize, 1), trace.destructor_count);
    resource.deinit();
}

test "generated zero-request interface resource and decoder analyze" {
    var owner = Owner.init();
    defer owner.deinit();
    var resource = EmptyFixture.Resource.init(std.testing.allocator, 51, 1, .server, owner.hooks());

    var message: wayring.wire.DecodedMessage = .{
        .allocator = std.testing.allocator,
        .descriptor = &Fixture.event_messages[0],
        .body = try std.testing.allocator.alloc(u8, 0),
        .values = try std.testing.allocator.alloc(wayring.wire.Value, 0),
    };
    defer message.deinit();
    try std.testing.expectError(error.InvalidRequestDescriptor, EmptyFixture.decodeRequest(0, &message));

    resource.destroy();
    resource.deinit();
}
