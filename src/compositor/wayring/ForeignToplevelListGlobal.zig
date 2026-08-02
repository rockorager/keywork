//! Discovery-only ext-foreign-toplevel-list-v1 adapter for native XDG roles.

const ForeignToplevelListGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const SecurityContextGlobal = @import("SecurityContextGlobal.zig");
const XdgShell = @import("XdgShell.zig");

allocator: std.mem.Allocator,
server: *Server,
shell: *XdgShell,
global_name: u32,
lists: std.ArrayList(*List) = .empty,
episodes: std.ArrayList(*Episode) = .empty,
handles: std.ArrayList(*Handle) = .empty,
next_identifier: u64 = 1,

const List = struct {
    owner: *ForeignToplevelListGlobal,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    stopped: bool = false,
    handles: std.ArrayList(*Handle) = .empty,
};

const Episode = struct {
    id: XdgShell.ToplevelId,
    identifier: [32]u8,
    identifier_len: u8,
    handles: std.ArrayList(*Handle) = .empty,
};

const Handle = struct {
    owner: *ForeignToplevelListGlobal,
    list: ?*List,
    episode: ?*Episode,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
    closed: bool = false,
};

pub fn init(self: *ForeignToplevelListGlobal, allocator: std.mem.Allocator, server: *Server, shell: *XdgShell, security: *SecurityContextGlobal) !void {
    self.* = .{ .allocator = allocator, .server = server, .shell = shell, .global_name = undefined };
    self.global_name = try server.createGlobal(&generated.ext_foreign_toplevel_list_v1, 1, .{
        .context = self,
        .bind = bind,
        .filter_context = security,
        .filter = SecurityContextGlobal.allowUnconfined,
    });
    shell.setToplevelObserver(.{
        .context = self,
        .published = published,
        .unpublished = unpublished,
        .metadata_changed = metadataChanged,
    });
}

pub fn deinit(self: *ForeignToplevelListGlobal) void {
    self.shell.clearToplevelObserver(self);
    self.server.removeGlobal(self.global_name) catch unreachable;
    std.debug.assert(self.lists.items.len == 0 and self.episodes.items.len == 0 and self.handles.items.len == 0);
    self.lists.deinit(self.allocator);
    self.episodes.deinit(self.allocator);
    self.handles.deinit(self.allocator);
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *ForeignToplevelListGlobal = @ptrCast(@alignCast(context));
    const list = self.allocator.create(List) catch return client.postNoMemory();
    errdefer self.allocator.destroy(list);
    list.* = .{ .owner = self, .client = client, .resource = undefined };
    self.lists.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
    list.resource = client.createResource(id, &generated.ext_foreign_toplevel_list_v1, version, .{ .context = list, .dispatch = dispatchList, .destroy = destroyList }) catch return client.postNoMemory();
    self.lists.appendAssumeCapacity(list);
    for (self.episodes.items) |episode| self.createHandle(list, episode) catch {
        client.postNoMemory() catch {};
        return;
    };
}

fn dispatchList(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const list: *List = @ptrCast(@alignCast(context));
    switch (try generated.ext_foreign_toplevel_list_v1_types.decodeRequest(&client.connection, resource, message)) {
        .destroy => {},
        .stop => if (!list.stopped) {
            list.stopped = true;
            try generated.ext_foreign_toplevel_list_v1_types.events.finished(&client.connection, resource);
        },
    }
}

fn destroyList(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const list: *List = @ptrCast(@alignCast(context));
    for (list.handles.items) |handle| handle.list = null;
    const owner = list.owner;
    _ = owner.lists.swapRemove(std.mem.indexOfScalar(*List, owner.lists.items, list) orelse unreachable);
    list.handles.deinit(owner.allocator);
    owner.allocator.destroy(list);
}

fn dispatchHandle(_: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    switch (try generated.ext_foreign_toplevel_handle_v1_types.decodeRequest(&client.connection, resource, message)) {
        .destroy => {},
    }
}

fn destroyHandle(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const handle: *Handle = @ptrCast(@alignCast(context));
    if (handle.list) |list| _ = list.handles.swapRemove(std.mem.indexOfScalar(*Handle, list.handles.items, handle) orelse unreachable);
    if (handle.episode) |episode| _ = episode.handles.swapRemove(std.mem.indexOfScalar(*Handle, episode.handles.items, handle) orelse unreachable);
    _ = handle.owner.handles.swapRemove(std.mem.indexOfScalar(*Handle, handle.owner.handles.items, handle) orelse unreachable);
    handle.owner.allocator.destroy(handle);
}

fn createHandle(self: *ForeignToplevelListGlobal, list: *List, episode: *Episode) !void {
    try list.handles.ensureUnusedCapacity(self.allocator, 1);
    try episode.handles.ensureUnusedCapacity(self.allocator, 1);
    try self.handles.ensureUnusedCapacity(self.allocator, 1);
    const handle = try self.allocator.create(Handle);
    errdefer self.allocator.destroy(handle);
    handle.* = .{ .owner = self, .list = list, .episode = episode, .client = list.client, .resource = undefined };
    handle.resource = try list.client.createServerResource(&generated.ext_foreign_toplevel_handle_v1, 1, .{ .context = handle, .dispatch = dispatchHandle, .destroy = destroyHandle });
    list.handles.appendAssumeCapacity(handle);
    episode.handles.appendAssumeCapacity(handle);
    self.handles.appendAssumeCapacity(handle);
    generated.ext_foreign_toplevel_list_v1_types.events.toplevel(&list.client.connection, list.resource, handle.resource) catch {
        list.client.postNoMemory() catch {};
        return;
    };
    self.sendProperties(handle) catch list.client.postNoMemory() catch {};
}

fn sendProperties(self: *ForeignToplevelListGlobal, handle: *Handle) !void {
    const episode = handle.episode orelse return;
    const metadata = self.shell.toplevelInfo(episode.id) orelse return;
    const identifier = episode.identifier[0..episode.identifier_len];
    try generated.ext_foreign_toplevel_handle_v1_types.events.identifier(&handle.client.connection, handle.resource, identifier);
    if (metadata.title) |title| try generated.ext_foreign_toplevel_handle_v1_types.events.title(&handle.client.connection, handle.resource, title);
    if (metadata.app_id) |app_id| try generated.ext_foreign_toplevel_handle_v1_types.events.app_id(&handle.client.connection, handle.resource, app_id);
    try generated.ext_foreign_toplevel_handle_v1_types.events.done(&handle.client.connection, handle.resource);
}

fn published(context: *anyopaque, id: XdgShell.ToplevelId) !void {
    const self: *ForeignToplevelListGlobal = @ptrCast(@alignCast(context));
    const episode = try self.allocator.create(Episode);
    errdefer self.allocator.destroy(episode);
    var buffer: [32]u8 = undefined;
    const identifier = try std.fmt.bufPrint(&buffer, "keywork-{d}", .{self.next_identifier});
    self.next_identifier = try std.math.add(u64, self.next_identifier, 1);
    episode.* = .{ .id = id, .identifier = undefined, .identifier_len = @intCast(identifier.len) };
    @memcpy(episode.identifier[0..identifier.len], identifier);
    try self.episodes.append(self.allocator, episode);
    for (self.lists.items) |list| if (!list.stopped) self.createHandle(list, episode) catch {
        list.client.postNoMemory() catch {};
    };
}

fn unpublished(context: *anyopaque, id: XdgShell.ToplevelId) void {
    const self: *ForeignToplevelListGlobal = @ptrCast(@alignCast(context));
    for (self.episodes.items, 0..) |episode, index| if (episode.id == id) {
        for (episode.handles.items) |handle| {
            if (handle.closed) continue;
            handle.closed = true;
            handle.episode = null;
            if (handle.client.state == .active)
                generated.ext_foreign_toplevel_handle_v1_types.events.closed(&handle.client.connection, handle.resource) catch handle.client.postNoMemory() catch {};
        }
        episode.handles.deinit(self.allocator);
        _ = self.episodes.swapRemove(index);
        self.allocator.destroy(episode);
        return;
    };
}

fn metadataChanged(context: *anyopaque, id: XdgShell.ToplevelId, field: XdgShell.ToplevelMetadataField) void {
    const self: *ForeignToplevelListGlobal = @ptrCast(@alignCast(context));
    const metadata = self.shell.toplevelInfo(id) orelse return;
    const value = switch (field) {
        .title => metadata.title,
        .app_id => metadata.app_id,
    } orelse unreachable;
    for (self.episodes.items) |episode| if (episode.id == id) for (episode.handles.items) |handle| {
        if (handle.closed or handle.client.state != .active) continue;
        (switch (field) {
            .title => generated.ext_foreign_toplevel_handle_v1_types.events.title(
                &handle.client.connection,
                handle.resource,
                value,
            ),
            .app_id => generated.ext_foreign_toplevel_handle_v1_types.events.app_id(
                &handle.client.connection,
                handle.resource,
                value,
            ),
        }) catch {
            handle.client.postNoMemory() catch {};
            continue;
        };
        generated.ext_foreign_toplevel_handle_v1_types.events.done(&handle.client.connection, handle.resource) catch handle.client.postNoMemory() catch {};
    };
}

const TestSnapshot = struct {
    handle: wayring.ObjectHandle,
    identifier: [32]u8,
    identifier_len: usize,
};

test "foreign toplevel list publishes applied XDG mapping episodes" {
    const core = @import("wayring-core");
    const CompositorGlobal = @import("CompositorGlobal.zig");
    const SurfaceTree = @import("SurfaceTree.zig");
    const render = @import("../render/types.zig");
    const allocator = std.testing.allocator;

    const Geometry = struct {
        fn surfaceSize(_: *anyopaque, _: *const CompositorGlobal.Surface) ?render.Size {
            return .{ .width = 1280, .height = 720 };
        }

        fn outputBounds(_: *anyopaque) render.Rect {
            return .{ .x = 0, .y = 0, .width = 1280, .height = 720 };
        }
    };

    var server = Server.init(allocator);
    defer server.deinit();
    var transport: @import("wayring-server-uring") = undefined;
    var security: SecurityContextGlobal = undefined;
    try security.init(allocator, &server, &transport);
    defer security.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(allocator, &server);
    defer compositor.deinit();
    var tree = SurfaceTree.init(allocator);
    defer tree.deinit();
    var geometry_context: u8 = 0;
    var shell: XdgShell = undefined;
    try shell.init(allocator, &server, &tree, .{
        .context = &geometry_context,
        .surface_size = Geometry.surfaceSize,
        .output_bounds = Geometry.outputBounds,
    });
    defer shell.deinit();
    var foreign: ForeignToplevelListGlobal = undefined;
    try foreign.init(allocator, &server, &shell, &security);
    defer foreign.deinit();

    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;
    var peer = wayring.Connection.init(allocator, .client, wayring.default_max_frame_size);
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{ .id = 2, .generation = try core.getRegistry(&peer, 2) };
    try testTransferToServer(&peer, client);
    try testTransferFromServer(&peer, client);

    var compositor_name: u32 = 0;
    var shell_name: u32 = 0;
    var foreign_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const event = try core.decodeRegistryEvent(&message, registry.id);
        if (event != .global) continue;
        if (std.mem.eql(u8, event.global.interface, generated.wl_compositor.name))
            compositor_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.xdg_wm_base.name))
            shell_name = event.global.name;
        if (std.mem.eql(u8, event.global.interface, generated.ext_foreign_toplevel_list_v1.name)) {
            foreign_name = event.global.name;
            try std.testing.expectEqual(@as(u32, 1), event.global.version);
        }
    }
    try std.testing.expect(compositor_name != 0 and shell_name != 0 and foreign_name != 0);

    const compositor_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(&peer, registry.id, compositor_name, generated.wl_compositor.name, 6, 3, &generated.wl_compositor),
    };
    const wm_base: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(&peer, registry.id, shell_name, generated.xdg_wm_base.name, 6, 4, &generated.xdg_wm_base),
    };
    const list = try core.bind(
        &peer,
        registry.id,
        foreign_name,
        generated.ext_foreign_toplevel_list_v1.name,
        1,
        5,
        &generated.ext_foreign_toplevel_list_v1,
    );
    const list_handle: wayring.ObjectHandle = .{ .id = 5, .generation = list };
    try testTransferToServer(&peer, client);
    try testTransferFromServer(&peer, client);
    try std.testing.expect(peer.popMessage() == null);

    const surface = try generated.wl_compositor_types.requests.create_surface(&peer, compositor_resource);
    const xdg_surface = try generated.xdg_wm_base_types.requests.get_xdg_surface(&peer, wm_base, surface);
    const toplevel = try generated.xdg_surface_types.requests.get_toplevel(&peer, xdg_surface);
    try generated.xdg_toplevel_types.requests.set_title(&peer, toplevel, "Initial title");
    try generated.xdg_toplevel_types.requests.set_app_id(&peer, toplevel, "org.example.App");
    try testTransferToServer(&peer, client);
    try testTransferFromServer(&peer, client);
    // Preparing a role and metadata does not publish a ghost mapping.
    try std.testing.expect(peer.popMessage() == null);

    const server_surface = try testServerSurface(client, surface.id);
    try shell.applied(server_surface, true);
    try testTransferFromServer(&peer, client);
    const first = try testSnapshot(&peer, list_handle, "Initial title", "org.example.App");
    try std.testing.expectEqualStrings("keywork-1", first.identifier[0..first.identifier_len]);

    try generated.xdg_toplevel_types.requests.set_title(&peer, toplevel, "");
    try testTransferToServer(&peer, client);
    try testTransferFromServer(&peer, client);
    var title_message = peer.popMessage() orelse return error.MissingTitleUpdate;
    defer title_message.deinit();
    try std.testing.expectEqual(first.handle.id, title_message.object_id);
    switch (try generated.ext_foreign_toplevel_handle_v1_types.decodeEvent(&peer, first.handle, &title_message)) {
        .title => |event| try std.testing.expectEqualStrings("", event.title),
        else => return error.UnexpectedTitleUpdate,
    }
    var title_done = peer.popMessage() orelse return error.MissingTitleDone;
    defer title_done.deinit();
    try std.testing.expect((try generated.ext_foreign_toplevel_handle_v1_types.decodeEvent(&peer, first.handle, &title_done)) == .done);
    try std.testing.expect(peer.popMessage() == null);

    try generated.ext_foreign_toplevel_list_v1_types.requests.stop(&peer, list_handle);
    try testTransferToServer(&peer, client);
    try testTransferFromServer(&peer, client);
    var finished_message = peer.popMessage() orelse return error.MissingFinished;
    defer finished_message.deinit();
    try std.testing.expect((try generated.ext_foreign_toplevel_list_v1_types.decodeEvent(&peer, list_handle, &finished_message)) == .finished);
    try generated.ext_foreign_toplevel_list_v1_types.requests.destroy(&peer, list_handle);
    try testTransferToServer(&peer, client);
    try testTransferFromServer(&peer, client);
    try testDrainDisplay(&peer);

    // Child handles remain live after stop and list destruction.
    try generated.xdg_toplevel_types.requests.set_app_id(&peer, toplevel, "org.example.Updated");
    try testTransferToServer(&peer, client);
    try testTransferFromServer(&peer, client);
    var app_message = peer.popMessage() orelse return error.MissingAppIdUpdate;
    defer app_message.deinit();
    switch (try generated.ext_foreign_toplevel_handle_v1_types.decodeEvent(&peer, first.handle, &app_message)) {
        .app_id => |event| try std.testing.expectEqualStrings("org.example.Updated", event.app_id),
        else => return error.UnexpectedAppIdUpdate,
    }
    var app_done = peer.popMessage() orelse return error.MissingAppIdDone;
    defer app_done.deinit();
    try std.testing.expect((try generated.ext_foreign_toplevel_handle_v1_types.decodeEvent(&peer, first.handle, &app_done)) == .done);

    try shell.applied(server_surface, false);
    try testTransferFromServer(&peer, client);
    var closed_message = peer.popMessage() orelse return error.MissingClosed;
    defer closed_message.deinit();
    try std.testing.expect((try generated.ext_foreign_toplevel_handle_v1_types.decodeEvent(&peer, first.handle, &closed_message)) == .closed);

    // A remap creates a fresh episode. A new list receives it through initial
    // replay, and destroying that handle never recreates it for the episode.
    try shell.applied(server_surface, true);
    const list_two: wayring.ObjectHandle = .{
        .id = 20,
        .generation = try core.bind(
            &peer,
            registry.id,
            foreign_name,
            generated.ext_foreign_toplevel_list_v1.name,
            1,
            20,
            &generated.ext_foreign_toplevel_list_v1,
        ),
    };
    try testTransferToServer(&peer, client);
    try testTransferFromServer(&peer, client);
    const second = try testSnapshot(&peer, list_two, "", "org.example.Updated");
    try std.testing.expectEqualStrings("keywork-2", second.identifier[0..second.identifier_len]);
    try std.testing.expect(!std.mem.eql(
        u8,
        first.identifier[0..first.identifier_len],
        second.identifier[0..second.identifier_len],
    ));
    try generated.ext_foreign_toplevel_handle_v1_types.requests.destroy(&peer, second.handle);
    try testTransferToServer(&peer, client);
    try generated.xdg_toplevel_types.requests.set_title(&peer, toplevel, "not recreated");
    try testTransferToServer(&peer, client);
    try testTransferFromServer(&peer, client);
    try std.testing.expect(peer.popMessage() == null);

    try generated.ext_foreign_toplevel_list_v1_types.requests.stop(&peer, list_two);
    try testTransferToServer(&peer, client);
    try testTransferFromServer(&peer, client);
    var second_finished = peer.popMessage() orelse return error.MissingFinished;
    defer second_finished.deinit();
    try std.testing.expect((try generated.ext_foreign_toplevel_list_v1_types.decodeEvent(&peer, list_two, &second_finished)) == .finished);
    try shell.applied(server_surface, false);
    try shell.applied(server_surface, true);
    try testTransferFromServer(&peer, client);
    try std.testing.expect(peer.popMessage() == null);

    const list_three: wayring.ObjectHandle = .{
        .id = 21,
        .generation = try core.bind(
            &peer,
            registry.id,
            foreign_name,
            generated.ext_foreign_toplevel_list_v1.name,
            1,
            21,
            &generated.ext_foreign_toplevel_list_v1,
        ),
    };
    try testTransferToServer(&peer, client);
    try testTransferFromServer(&peer, client);
    const third = try testSnapshot(&peer, list_three, "not recreated", "org.example.Updated");
    try std.testing.expectEqualStrings("keywork-3", third.identifier[0..third.identifier_len]);

    // Direct role teardown closes the published episode without waiting for
    // another surface transaction.
    try generated.xdg_toplevel_types.requests.destroy(&peer, toplevel);
    try testTransferToServer(&peer, client);
    try testTransferFromServer(&peer, client);
    var direct_closed = peer.popMessage() orelse return error.MissingDirectClosed;
    defer direct_closed.deinit();
    try std.testing.expect((try generated.ext_foreign_toplevel_handle_v1_types.decodeEvent(&peer, third.handle, &direct_closed)) == .closed);
    try testDrainDisplay(&peer);
}

test "foreign toplevel list replay OOM leaves registered resources owning cleanup" {
    const SurfaceTree = @import("SurfaceTree.zig");
    const render = @import("../render/types.zig");

    const Geometry = struct {
        fn surfaceSize(_: *anyopaque, _: *const @import("CompositorGlobal.zig").Surface) ?render.Size {
            return null;
        }

        fn outputBounds(_: *anyopaque) render.Rect {
            return .{ .x = 0, .y = 0, .width = 1280, .height = 720 };
        }
    };

    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var tree = SurfaceTree.init(std.testing.allocator);
    defer tree.deinit();
    var geometry_context: u8 = 0;
    var shell: XdgShell = undefined;
    try shell.init(std.testing.allocator, &server, &tree, .{
        .context = &geometry_context,
        .surface_size = Geometry.surfaceSize,
        .output_bounds = Geometry.outputBounds,
    });
    defer shell.deinit();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    const allocator = failing.allocator();
    var foreign: ForeignToplevelListGlobal = .{
        .allocator = allocator,
        .server = &server,
        .shell = &shell,
        .global_name = undefined,
    };
    defer foreign.handles.deinit(allocator);
    defer foreign.episodes.deinit(allocator);
    defer foreign.lists.deinit(allocator);

    var first: Episode = .{
        .id = @enumFromInt(1),
        .identifier = undefined,
        .identifier_len = 0,
    };
    defer first.handles.deinit(allocator);
    var second: Episode = .{
        .id = @enumFromInt(2),
        .identifier = undefined,
        .identifier_len = 0,
    };
    defer second.handles.deinit(allocator);
    try foreign.episodes.append(allocator, &first);
    try foreign.episodes.append(allocator, &second);
    try foreign.lists.ensureUnusedCapacity(allocator, 1);
    try foreign.handles.ensureUnusedCapacity(allocator, 1);
    try first.handles.ensureUnusedCapacity(allocator, 1);

    {
        const client = try server.createClient();
        defer server.destroyClient(client) catch unreachable;

        // Permit one replayed handle, then fail while constructing the next.
        // The list and first handle are already registered server resources.
        failing.fail_index = failing.alloc_index + 3;
        try bind(&foreign, client, 2, 1);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(Server.ClientState.protocol_error, client.state);
        try std.testing.expectEqual(@as(usize, 1), foreign.lists.items.len);
        try std.testing.expectEqual(@as(usize, 1), foreign.handles.items.len);
        try std.testing.expectEqual(@as(usize, 1), first.handles.items.len);
    }

    try std.testing.expectEqual(@as(usize, 0), foreign.lists.items.len);
    try std.testing.expectEqual(@as(usize, 0), foreign.handles.items.len);
    try std.testing.expectEqual(@as(usize, 0), first.handles.items.len);
}

fn testSnapshot(
    peer: *wayring.Connection,
    list: wayring.ObjectHandle,
    expected_title: []const u8,
    expected_app_id: []const u8,
) !TestSnapshot {
    var list_message = peer.popMessage() orelse return error.MissingToplevel;
    defer list_message.deinit();
    const new_id = switch (try generated.ext_foreign_toplevel_list_v1_types.decodeEvent(peer, list, &list_message)) {
        .toplevel => |event| event.toplevel,
        else => return error.UnexpectedListEvent,
    };
    const handle: wayring.ObjectHandle = .{
        .id = new_id,
        .generation = try peer.registerObject(new_id, &generated.ext_foreign_toplevel_handle_v1, 1),
    };
    try peer.resumeParsing();
    var snapshot: TestSnapshot = .{
        .handle = handle,
        .identifier = undefined,
        .identifier_len = 0,
    };
    const Expected = enum { identifier, title, app_id, done };
    const expected = [_]Expected{ .identifier, .title, .app_id, .done };
    for (expected) |kind| {
        var message = peer.popMessage() orelse return error.IncompleteToplevelSnapshot;
        defer message.deinit();
        switch (try generated.ext_foreign_toplevel_handle_v1_types.decodeEvent(peer, handle, &message)) {
            .identifier => |event| {
                try std.testing.expectEqual(Expected.identifier, kind);
                try std.testing.expect(event.identifier.len > 0 and event.identifier.len <= snapshot.identifier.len);
                snapshot.identifier_len = event.identifier.len;
                @memcpy(snapshot.identifier[0..event.identifier.len], event.identifier);
            },
            .title => |event| {
                try std.testing.expectEqual(Expected.title, kind);
                try std.testing.expectEqualStrings(expected_title, event.title);
            },
            .app_id => |event| {
                try std.testing.expectEqual(Expected.app_id, kind);
                try std.testing.expectEqualStrings(expected_app_id, event.app_id);
            },
            .done => try std.testing.expectEqual(Expected.done, kind),
            .closed => return error.UnexpectedClosed,
        }
    }
    try std.testing.expect(peer.popMessage() == null);
    return snapshot;
}

fn testServerSurface(client: *Server.Client, id: u32) !*@import("CompositorGlobal.zig").Surface {
    const CompositorGlobal = @import("CompositorGlobal.zig");
    const object = client.connection.object(id) orelse return error.MissingSurface;
    return CompositorGlobal.surfaceFor(client, .{ .id = id, .generation = object.generation });
}

fn testTransferToServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (connection.nextBatch()) |batch| {
        try client.receive(batch.bytes, batch.fds);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
}

fn testTransferFromServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (client.connection.nextBatch()) |batch| {
        try connection.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}

fn testDrainDisplay(connection: *wayring.Connection) !void {
    const core = @import("wayring-core");
    while (connection.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != 1) return error.UnexpectedEvent;
        _ = try core.decodeDisplayEvent(&message);
    }
}
