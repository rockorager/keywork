const std = @import("std");
const core = @import("core_protocol");
const wayring = @import("wayring");

const wire = wayring.wire;
const server = wayring.server;

const App = struct {
    client: ?*server.Client = null,
    compositor: ?core.wl_compositor.Resource = null,
    surface: ?core.wl_surface.Resource = null,
    binder_called: bool = false,
    compositor_called: bool = false,
    surface_called: bool = false,

    fn bind(client: *server.Client, id: u32, version: u32, self: *App) !void {
        self.binder_called = true;
        self.client = client;
        self.compositor = .init(std.testing.allocator, id, version, .client, client.ownerHooks());
        try self.compositor.?.setHandler(App, self, handleCompositor, null);
        try client.materialize(&self.compositor.?.runtime);
    }

    fn handleCompositor(resource: *core.wl_compositor.Resource, request: core.wl_compositor.Request, self: *App) !void {
        self.compositor_called = true;
        const id = request.create_surface.id;
        const version = @min(resource.version(), core.wl_surface.interface.version);
        self.surface = .init(std.testing.allocator, id, version, .client, self.client.?.ownerHooks());
        try self.surface.?.setHandler(App, self, handleSurface, null);
        try self.client.?.materialize(&self.surface.?.runtime);
    }

    fn handleSurface(resource: *core.wl_surface.Resource, request: core.wl_surface.Request, self: *App) !void {
        _ = request.destroy;
        self.surface_called = true;
        resource.destroy();
    }
};

fn encode(object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) ![]u8 {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    const result = try std.testing.allocator.dupe(u8, batch.bytes);
    try output.completeSend(batch.token, batch.bytes.len);
    return result;
}

fn send(client: *server.Client, object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
    const bytes = try encode(object_id, opcode, descriptor, values);
    defer std.testing.allocator.free(bytes);
    try client.receive(bytes, &.{});
    try client.dispatch();
}

fn drain(client: *server.Client) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(std.testing.allocator);
    while (try client.beginSend()) |batch| {
        try bytes.appendSlice(std.testing.allocator, batch.bytes);
        try client.completeSend(batch.token, batch.bytes.len);
    }
    return bytes.toOwnedSlice(std.testing.allocator);
}

fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

test "in-memory core exchange binds compositor and orders surface delete_id" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var app: App = .{};
    _ = try host.addGlobal(core.wl_compositor, 7, App, &app, App.bind);
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    defer managed.destroy();
    const client = managed.client();

    try send(client, 1, 1, &core.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
    const globals = try drain(client);
    defer std.testing.allocator.free(globals);
    try std.testing.expect(globals.len >= 24);
    try std.testing.expectEqual(@as(u32, 2), word(globals, 0));
    try std.testing.expectEqual(@as(u16, 0), @as(u16, @truncate(word(globals, 4))));
    const global_name = word(globals, 8);
    const name_len = word(globals, 12);
    try std.testing.expectEqualStrings("wl_compositor", globals[16 .. 16 + name_len - 1]);
    const padded_name_len = std.mem.alignForward(usize, name_len, 4);
    const advertised_version = word(globals, 16 + padded_name_len);

    try send(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = global_name },
        .{ .new_id = .{ .generic = .{ .interface = "wl_compositor", .version = advertised_version, .id = 3 } } },
    });
    try send(client, 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 4 } }});
    try send(client, 4, 0, &core.wl_surface.request_messages[0], &.{});
    const events = try drain(client);
    defer std.testing.allocator.free(events);
    try std.testing.expectEqual(@as(usize, 12), events.len);
    try std.testing.expectEqual(@as(u32, 1), word(events, 0));
    try std.testing.expectEqual(@as(u16, 1), @as(u16, @truncate(word(events, 4))));
    try std.testing.expectEqual(@as(u32, 4), word(events, 8));
    try std.testing.expect(app.binder_called and app.compositor_called and app.surface_called);
    try std.testing.expectEqual(@min(advertised_version, core.wl_surface.interface.version), app.surface.?.version());
    try std.testing.expect(client.fatal() == null);

    app.surface.?.deinit();
    app.compositor.?.destroy();
    app.compositor.?.deinit();
}
