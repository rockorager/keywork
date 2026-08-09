//! Restricted scanner-backed gamma control over canonical outputs.

const WayringGammaControl = @This();

const std = @import("std");
const protocol = @import("wayring-protocol");
const wayring = @import("wayring");
const OutputLayout = @import("../output_layout.zig");
const gamma_table = @import("gamma_table.zig");

const server = wayring.server;
const wire = wayring.wire;

pub const Listener = struct {
    context: *anyopaque,
    reserve: *const fn (*anyopaque, OutputLayout.Id) bool,
    release: *const fn (*anyopaque, OutputLayout.Id) void,
    gamma_size: *const fn (*anyopaque, OutputLayout.Id) ?u32,
    set_gamma: *const fn (*anyopaque, OutputLayout.Id, []const u16) bool,
    reset_gamma: *const fn (*anyopaque, OutputLayout.Id) void,
};

pub const Resolver = struct {
    context: *anyopaque,
    output_id: *const fn (*anyopaque, *server.Client, u32) ?OutputLayout.Id,
};

const Manager = struct {
    owner: *WayringGammaControl,
    client: *server.Client,
    resource: protocol.zwlr_gamma_control_manager_v1.Resource,
};

const Control = struct {
    owner: *WayringGammaControl,
    client: *server.Client,
    resource: protocol.zwlr_gamma_control_v1.Resource,
    output: ?OutputLayout.Id,
    gamma_size: u32,
    failed: bool = false,
};

allocator: std.mem.Allocator,
io: std.Io,
protocol_server: *server.Server,
resolver: Resolver,
authorized_uid: std.os.linux.uid_t,
listener: Listener,
global: ?*const server.Server.Global = null,
managers: std.ArrayList(*Manager) = .empty,
controls: std.ArrayList(*Control) = .empty,

pub fn init(self: *WayringGammaControl, allocator: std.mem.Allocator, io: std.Io, protocol_server: *server.Server, resolver: Resolver, authorized_uid: std.os.linux.uid_t, listener: Listener) void {
    self.* = .{ .allocator = allocator, .io = io, .protocol_server = protocol_server, .resolver = resolver, .authorized_uid = authorized_uid, .listener = listener };
}

pub fn publish(self: *WayringGammaControl) !void {
    std.debug.assert(self.global == null);
    self.global = try self.protocol_server.addGlobalWithOptions(protocol.zwlr_gamma_control_manager_v1, 1, WayringGammaControl, self, bind, .{ .visibility = .restricted });
}

pub fn unpublish(self: *WayringGammaControl) void {
    self.protocol_server.removeGlobal(self.global orelse unreachable) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.global = null;
}

pub fn globalFilter(self: *WayringGammaControl, client: *const server.Client, global: *const server.Server.Global) bool {
    return global.visibility() != .restricted or client.isAuthorizedDirectPeer(self.authorized_uid);
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringGammaControl) !void {
    try self.managers.ensureUnusedCapacity(self.allocator, 1);
    const manager = try self.allocator.create(Manager);
    errdefer self.allocator.destroy(manager);
    manager.* = .{ .owner = self, .client = client, .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        manager.resource.destroy();
        manager.resource.deinit();
    }
    try manager.resource.setHandler(Manager, manager, managerRequest, null);
    try client.materialize(&manager.resource.runtime);
    self.managers.appendAssumeCapacity(manager);
}

fn managerRequest(_: *protocol.zwlr_gamma_control_manager_v1.Resource, request: protocol.zwlr_gamma_control_manager_v1.Request, manager: *Manager) !void {
    switch (request) {
        .destroy => manager.owner.destroyManager(manager),
        .get_gamma_control => |args| try manager.owner.createControl(manager, args.id, args.output),
    }
}

fn createControl(self: *WayringGammaControl, manager: *Manager, id: u32, output_object: u32) !void {
    try self.controls.ensureUnusedCapacity(self.allocator, 1);
    const control = try self.allocator.create(Control);
    errdefer self.allocator.destroy(control);
    var output = self.resolver.output_id(self.resolver.context, manager.client, output_object);
    if (output) |candidate| {
        if (!self.listener.reserve(self.listener.context, candidate)) output = null;
    }
    errdefer if (output) |candidate| self.listener.release(self.listener.context, candidate);
    const gamma_size = if (output) |candidate| self.listener.gamma_size(self.listener.context, candidate) else null;
    if (output != null and gamma_size == null) {
        self.listener.release(self.listener.context, output.?);
        output = null;
    }
    control.* = .{ .owner = self, .client = manager.client, .resource = .init(self.allocator, id, manager.resource.version(), .client, manager.client.ownerHooks()), .output = output, .gamma_size = gamma_size orelse 0 };
    errdefer {
        control.resource.destroy();
        control.resource.deinit();
    }
    try control.resource.setHandler(Control, control, controlRequest, null);
    try manager.client.materialize(&control.resource.runtime);
    self.controls.appendAssumeCapacity(control);
    if (gamma_size) |size| {
        protocol.zwlr_gamma_control_v1.@"send:gamma_size"(&control.resource, size) catch |err| eventFailed(control, err);
    } else fail(control, false);
}

fn controlRequest(_: *protocol.zwlr_gamma_control_v1.Resource, request: protocol.zwlr_gamma_control_v1.Request, control: *Control) !void {
    switch (request) {
        .destroy => control.owner.destroyControl(control),
        .set_gamma => |args| {
            defer _ = std.c.close(args.fd);
            const output = control.output orelse return;
            const table = gamma_table.read(control.owner.io, control.owner.allocator, args.fd, control.gamma_size) catch |err| switch (err) {
                error.OutOfMemory => return control.client.postOutOfMemory(&control.resource.runtime, "reading gamma table"),
                error.InvalidGamma => return control.client.postProtocolError(&control.resource.runtime, @intCast(protocol.zwlr_gamma_control_v1.@"error".invalid_gamma), "invalid gamma table size"),
                error.ReadGammaFailed => return fail(control, true),
            };
            defer control.owner.allocator.free(table);
            if (!control.owner.listener.set_gamma(control.owner.listener.context, output, table)) fail(control, true);
        },
    }
}

fn fail(control: *Control, reset: bool) void {
    if (control.failed) return;
    control.failed = true;
    if (control.output) |output| {
        if (reset) control.owner.listener.reset_gamma(control.owner.listener.context, output);
        control.owner.listener.release(control.owner.listener.context, output);
    }
    control.output = null;
    protocol.zwlr_gamma_control_v1.@"send:failed"(&control.resource) catch |err| eventFailed(control, err);
}

fn eventFailed(control: *Control, _: anyerror) void {
    control.client.postOutOfMemory(&control.resource.runtime, "queueing gamma control event");
}

pub fn removeOutput(self: *WayringGammaControl, output: OutputLayout.Id) void {
    for (self.controls.items) |control| if (control.output) |current| if (std.meta.eql(current, output)) fail(control, true);
}

pub fn refreshOutputs(self: *WayringGammaControl) void {
    for (self.controls.items) |control| if (control.output) |output| {
        const size = self.listener.gamma_size(self.listener.context, output) orelse {
            fail(control, true);
            continue;
        };
        if (size != control.gamma_size) fail(control, true);
    };
}

pub fn destroyClientResources(self: *WayringGammaControl, client: *server.Client) void {
    var i = self.controls.items.len;
    while (i > 0) : (i -= 1) if (self.controls.items[i - 1].client == client) self.destroyControl(self.controls.items[i - 1]);
    i = self.managers.items.len;
    while (i > 0) : (i -= 1) if (self.managers.items[i - 1].client == client) self.destroyManager(self.managers.items[i - 1]);
}

fn destroyControl(self: *WayringGammaControl, control: *Control) void {
    if (control.output) |output| {
        self.listener.reset_gamma(self.listener.context, output);
        self.listener.release(self.listener.context, output);
    }
    _ = self.controls.swapRemove(std.mem.indexOfScalar(*Control, self.controls.items, control).?);
    control.resource.destroy();
    control.resource.deinit();
    self.allocator.destroy(control);
}

fn destroyManager(self: *WayringGammaControl, manager: *Manager) void {
    _ = self.managers.swapRemove(std.mem.indexOfScalar(*Manager, self.managers.items, manager).?);
    manager.resource.destroy();
    manager.resource.deinit();
    self.allocator.destroy(manager);
}

pub fn deinit(self: *WayringGammaControl) void {
    std.debug.assert(self.global == null and self.managers.items.len == 0 and self.controls.items.len == 0);
    self.managers.deinit(self.allocator);
    self.controls.deinit(self.allocator);
    self.* = undefined;
}

test "generated gamma descriptors preserve typed output fd and error" {
    try std.testing.expectEqualStrings("wl_output", protocol.zwlr_gamma_control_manager_v1.request_0_arguments[1].kind.object.interface.?.name);
    try std.testing.expect(protocol.zwlr_gamma_control_v1.request_0_arguments[0].kind == .fd);
    try std.testing.expectEqual(@as(i64, 1), protocol.zwlr_gamma_control_v1.@"error".invalid_gamma);
}

const TestBackend = struct {
    gamma_size_value: ?u32 = 2,
    reserved: bool = false,
    reserve_calls: usize = 0,
    release_calls: usize = 0,
    reset_calls: usize = 0,
    set_calls: usize = 0,
    received: [6]u16 = undefined,

    fn reserve(context: *anyopaque, _: OutputLayout.Id) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.reserve_calls += 1;
        if (self.reserved) return false;
        self.reserved = true;
        return true;
    }

    fn release(context: *anyopaque, _: OutputLayout.Id) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        std.debug.assert(self.reserved);
        self.reserved = false;
        self.release_calls += 1;
    }

    fn gammaSize(context: *anyopaque, _: OutputLayout.Id) ?u32 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.gamma_size_value;
    }

    fn setGamma(context: *anyopaque, _: OutputLayout.Id, table: []const u16) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.set_calls += 1;
        std.debug.assert(table.len == self.received.len);
        @memcpy(&self.received, table);
        return true;
    }

    fn resetGamma(context: *anyopaque, _: OutputLayout.Id) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.reset_calls += 1;
    }
};

const GammaHarness = struct {
    const output_id: OutputLayout.Id = .{ .index = 7, .generation = 3 };

    host: server.Server,
    backend: TestBackend,
    adapter: WayringGammaControl,
    managed: *server.CoreClient,
    output_resource: protocol.wl_output.Resource,
    unresolved_resource: protocol.wl_output.Resource,

    fn init(self: *@This()) !void {
        self.host = .init(std.testing.allocator);
        self.backend = .{};
        self.managed = try server.CoreClient.create(std.testing.allocator, &self.host, .{});
        self.output_resource = .init(std.testing.allocator, 2, 1, .client, self.client().ownerHooks());
        try self.client().installClientInitial(2, &self.output_resource.runtime);
        self.unresolved_resource = .init(std.testing.allocator, 3, 1, .client, self.client().ownerHooks());
        try self.client().installClientInitial(3, &self.unresolved_resource.runtime);
        self.adapter.init(std.testing.allocator, std.testing.io, &self.host, .{ .context = self, .output_id = resolve }, 0, .{
            .context = &self.backend,
            .reserve = TestBackend.reserve,
            .release = TestBackend.release,
            .gamma_size = TestBackend.gammaSize,
            .set_gamma = TestBackend.setGamma,
            .reset_gamma = TestBackend.resetGamma,
        });
    }

    fn deinit(self: *@This()) void {
        self.adapter.destroyClientResources(self.client());
        self.output_resource.destroy();
        self.output_resource.deinit();
        self.unresolved_resource.destroy();
        self.unresolved_resource.deinit();
        self.managed.destroy();
        self.adapter.deinit();
        self.host.deinit();
    }

    fn client(self: *@This()) *server.Client {
        return self.managed.client();
    }

    fn resolve(context: *anyopaque, candidate_client: *server.Client, object_id: u32) ?OutputLayout.Id {
        const self: *@This() = @ptrCast(@alignCast(context));
        return if (candidate_client == self.client() and object_id == 2) output_id else null;
    }

    fn bindManager(self: *@This()) !void {
        const manager = try std.testing.allocator.create(Manager);
        errdefer std.testing.allocator.destroy(manager);
        manager.* = .{ .owner = &self.adapter, .client = self.client(), .resource = .init(std.testing.allocator, 4, 1, .client, self.client().ownerHooks()) };
        errdefer manager.resource.deinit();
        try manager.resource.setHandler(Manager, manager, managerRequest, null);
        try self.client().installClientInitial(4, &manager.resource.runtime);
        try self.adapter.managers.append(std.testing.allocator, manager);
    }

    fn send(self: *@This(), object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
        var output: wire.Output = .init(std.testing.allocator);
        defer output.deinit();
        try output.enqueue(object_id, opcode, descriptor, values);
        const batch = (try output.beginSend()).?;
        try self.client().receive(batch.bytes, &.{});
        try output.completeSend(batch.token, batch.bytes.len);
        try self.client().dispatch();
    }

    fn sendWithFd(self: *@This(), id: u32, fd: std.posix.fd_t) !void {
        var output: wire.Output = .init(std.testing.allocator);
        defer output.deinit();
        try output.enqueue(id, 0, &protocol.zwlr_gamma_control_v1.request_messages[0], &.{.{ .fd = fd }});
        const batch = (try output.beginSend()).?;
        const duplicate = std.c.fcntl(batch.fds[0], std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (duplicate < 0) return error.Unexpected;
        errdefer _ = std.c.close(duplicate);
        try self.client().receive(batch.bytes, &.{duplicate});
        try output.completeSend(batch.token, batch.bytes.len);
        try self.client().dispatch();
    }

    fn getControl(self: *@This(), id: u32, output_object: u32) !void {
        try self.send(4, 0, &protocol.zwlr_gamma_control_manager_v1.request_messages[0], &.{
            .{ .new_id = .{ .typed = id } },
            .{ .object = output_object },
        });
    }

    fn drain(self: *@This()) ![]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(std.testing.allocator);
        while (try self.client().beginSend()) |batch| {
            try bytes.appendSlice(std.testing.allocator, batch.bytes);
            try self.client().completeSend(batch.token, batch.bytes.len);
        }
        return bytes.toOwnedSlice(std.testing.allocator);
    }
};

fn gammaMemfd(values: []const u16) !std.posix.fd_t {
    const fd = try std.posix.memfd_create("keywork-wayring-gamma-test", std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.c.close(fd);
    const bytes = std.mem.sliceAsBytes(values);
    if (std.os.linux.errno(std.os.linux.ftruncate(fd, @intCast(bytes.len))) != .SUCCESS) return error.Unexpected;
    if (std.c.write(fd, bytes.ptr, bytes.len) != bytes.len) return error.Unexpected;
    return fd;
}

test "gamma control creation sends size and reserves output" {
    var harness: GammaHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bindManager();
    try harness.getControl(5, 2);
    const events = try harness.drain();
    defer std.testing.allocator.free(events);
    try std.testing.expectEqual(@as(usize, 12), events.len);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, events[8..12], .native));
    try std.testing.expect(harness.backend.reserved);
    try std.testing.expectEqual(@as(usize, 1), harness.backend.reserve_calls);
}

test "duplicate and unresolved gamma controls fail without replacing original" {
    var harness: GammaHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bindManager();
    try harness.getControl(5, 2);
    var events = try harness.drain();
    std.testing.allocator.free(events);
    try harness.getControl(6, 2);
    events = try harness.drain();
    try std.testing.expect(events.len > 0);
    std.testing.allocator.free(events);
    try harness.getControl(7, 3);
    events = try harness.drain();
    try std.testing.expect(events.len > 0);
    std.testing.allocator.free(events);
    try std.testing.expect(harness.adapter.controls.items[0].output != null);
    try std.testing.expect(harness.adapter.controls.items[1].output == null);
    try std.testing.expect(harness.adapter.controls.items[2].output == null);
    try std.testing.expect(harness.backend.reserved);
}

test "exact gamma memfd dispatches exact table" {
    var harness: GammaHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bindManager();
    try harness.getControl(5, 2);
    const events = try harness.drain();
    std.testing.allocator.free(events);
    const expected = [_]u16{ 1, 2, 3, 100, 200, 65535 };
    const fd = try gammaMemfd(&expected);
    defer _ = std.c.close(fd);
    try harness.sendWithFd(5, fd);
    try std.testing.expectEqual(@as(usize, 1), harness.backend.set_calls);
    try std.testing.expectEqualSlices(u16, &expected, &harness.backend.received);
}

test "wrong size gamma memfd posts invalid gamma without setting" {
    var harness: GammaHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bindManager();
    try harness.getControl(5, 2);
    const events = try harness.drain();
    std.testing.allocator.free(events);
    const short = [_]u16{ 1, 2, 3 };
    const fd = try gammaMemfd(&short);
    defer _ = std.c.close(fd);
    try harness.sendWithFd(5, fd);
    const fatal = harness.client().fatal().?;
    try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
    try std.testing.expectEqual(@as(?u32, @intCast(protocol.zwlr_gamma_control_v1.@"error".invalid_gamma)), fatal.protocol_code);
    try std.testing.expectEqual(@as(usize, 0), harness.backend.set_calls);
}

test "gamma output removal and refresh fail reset and release once" {
    var harness: GammaHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bindManager();
    try harness.getControl(5, 2);
    var events = try harness.drain();
    std.testing.allocator.free(events);
    harness.adapter.removeOutput(GammaHarness.output_id);
    events = try harness.drain();
    try std.testing.expect(events.len > 0);
    std.testing.allocator.free(events);
    harness.adapter.removeOutput(GammaHarness.output_id);
    try std.testing.expectEqual(@as(usize, 1), harness.backend.reset_calls);
    try std.testing.expectEqual(@as(usize, 1), harness.backend.release_calls);

    try harness.getControl(6, 2);
    events = try harness.drain();
    std.testing.allocator.free(events);
    harness.backend.gamma_size_value = 3;
    harness.adapter.refreshOutputs();
    events = try harness.drain();
    try std.testing.expect(events.len > 0);
    std.testing.allocator.free(events);
    harness.adapter.refreshOutputs();
    try std.testing.expectEqual(@as(usize, 2), harness.backend.reset_calls);
    try std.testing.expectEqual(@as(usize, 2), harness.backend.release_calls);
}

test "gamma disconnect cleanup resets and releases exactly once" {
    var harness: GammaHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try harness.bindManager();
    try harness.getControl(5, 2);
    harness.adapter.destroyClientResources(harness.client());
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.managers.items.len);
    try std.testing.expectEqual(@as(usize, 0), harness.adapter.controls.items.len);
    try std.testing.expectEqual(@as(usize, 1), harness.backend.reset_calls);
    try std.testing.expectEqual(@as(usize, 1), harness.backend.release_calls);
}
