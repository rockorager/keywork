//! Native `wl_subcompositor` policy and synchronized commit aggregation.

const SubcompositorGlobal = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const SurfaceTree = @import("SurfaceTree.zig");

allocator: std.mem.Allocator,
server: *Server,
compositor: *CompositorGlobal,
tree: *SurfaceTree,
global_name: u32,
subsurfaces: std.ArrayList(*Subsurface) = .empty,

const Subsurface = struct {
    owner: *SubcompositorGlobal,
    resource: wayring.ObjectHandle,
    node: *SurfaceTree.Node,
    synchronized: bool = true,
    inert: bool = false,
    cached: ?Fragment = null,
};

const Fragment = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(CompositorGlobal.Commit) = .empty,
    updates: std.ArrayList(CompositorGlobal.HierarchyUpdate) = .empty,

    fn deinit(self: *Fragment) void {
        for (self.updates.items) |update| update.deinit(update.context);
        self.updates.deinit(self.allocator);
        for (self.entries.items) |*commit| {
            commit.releaseBuffer() catch {};
            commit.deinit();
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
};

const OwnedUpdate = struct {
    allocator: std.mem.Allocator,
    update: SurfaceTree.Update,
};

pub fn init(self: *SubcompositorGlobal, allocator: std.mem.Allocator, server: *Server, compositor: *CompositorGlobal, tree: *SurfaceTree) !void {
    self.* = .{ .allocator = allocator, .server = server, .compositor = compositor, .tree = tree, .global_name = undefined };
    self.global_name = try server.createGlobal(&generated.wl_subcompositor, 1, .{ .context = self, .bind = bind });
    compositor.setHierarchyHandler(.{ .context = self, .commit = handleCommit, .surface_destroyed = surfaceDestroyed });
}

pub fn deinit(self: *SubcompositorGlobal) void {
    self.compositor.clearHierarchyHandler(self);
    self.server.removeGlobal(self.global_name) catch unreachable;
    std.debug.assert(self.subsurfaces.items.len == 0);
    self.subsurfaces.deinit(self.allocator);
    self.* = undefined;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *SubcompositorGlobal = @ptrCast(@alignCast(context));
    _ = client.createResource(id, &generated.wl_subcompositor, version, .{ .context = self, .dispatch = dispatchSubcompositor }) catch return client.postNoMemory();
}

fn dispatchSubcompositor(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const self: *SubcompositorGlobal = @ptrCast(@alignCast(context));
    switch (try generated.wl_subcompositor_types.decodeRequest(&client.connection, resource, message)) {
        .destroy => {},
        .get_subsurface => |request| {
            const child_object = client.connection.object(request.surface) orelse
                return badSurface(client, resource, "invalid child surface");
            const parent_object = client.connection.object(request.parent) orelse
                return badParent(client, resource, "invalid parent surface");
            const child = CompositorGlobal.surfaceFor(client, .{ .id = request.surface, .generation = child_object.generation }) catch return badSurface(client, resource, "invalid child surface");
            const parent = CompositorGlobal.surfaceFor(client, .{ .id = request.parent, .generation = parent_object.generation }) catch return badParent(client, resource, "invalid parent surface");
            if (child == parent or child.role_context != null) return badSurface(client, resource, "surface already has a role");
            const child_node = self.tree.nodeFor(child) catch return client.postNoMemory();
            const parent_node = self.tree.nodeFor(parent) catch return client.postNoMemory();
            if (SurfaceTree.wouldCycle(child_node, parent_node)) return badParent(client, resource, "subsurface parent cycle");
            const subsurface = self.allocator.create(Subsurface) catch return client.postNoMemory();
            errdefer self.allocator.destroy(subsurface);
            subsurface.* = .{ .owner = self, .resource = undefined, .node = child_node };
            child.setRole(self, subsurface, childRoleDestroyed) catch return badSurface(client, resource, "surface already has a role");
            errdefer child.clearRole(subsurface);
            self.tree.attach(child_node, parent_node, .parent) catch return badParent(client, resource, "invalid subsurface parent");
            errdefer self.tree.detach(child_node);
            self.subsurfaces.ensureUnusedCapacity(self.allocator, 1) catch return client.postNoMemory();
            subsurface.resource = client.createResource(request.id, &generated.wl_subsurface, 1, .{ .context = subsurface, .dispatch = dispatchSubsurface, .destroy = destroySubsurface }) catch return client.postNoMemory();
            self.subsurfaces.appendAssumeCapacity(subsurface);
        },
    }
}

fn dispatchSubsurface(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const subsurface: *Subsurface = @ptrCast(@alignCast(context));
    switch (try generated.wl_subsurface_types.decodeRequest(&client.connection, resource, message)) {
        .destroy => {},
        .set_position => |request| if (!subsurface.inert) SurfaceTree.setPosition(subsurface.node, request.x, request.y),
        .place_above => |request| try placeRequest(subsurface, client, resource, request.sibling, true),
        .place_below => |request| try placeRequest(subsurface, client, resource, request.sibling, false),
        .set_sync => if (!subsurface.inert) {
            subsurface.synchronized = true;
        },
        .set_desync => if (!subsurface.inert) {
            subsurface.synchronized = false;
            flushNewlyDesynchronized(subsurface.owner, subsurface.node) catch
                return client.postNoMemory();
        },
    }
}

fn placeRequest(subsurface: *Subsurface, client: *Server.Client, resource: wayring.ObjectHandle, sibling_id: u32, above: bool) !void {
    if (subsurface.inert) return;
    const object = client.connection.object(sibling_id) orelse return badSurface(client, resource, "invalid sibling");
    const sibling_surface = CompositorGlobal.surfaceFor(client, .{ .id = sibling_id, .generation = object.generation }) catch return badSurface(client, resource, "invalid sibling");
    const sibling = subsurface.owner.tree.find(sibling_surface) orelse return badSurface(client, resource, "reference is not parent or sibling");
    SurfaceTree.place(subsurface.node, sibling, above) catch return badSurface(client, resource, "reference is not parent or sibling");
}

fn badSurface(client: *Server.Client, resource: wayring.ObjectHandle, text: []const u8) !void {
    return client.postError(resource, @intFromEnum(generated.wl_subcompositor_types.@"error".bad_surface), text);
}
fn badParent(client: *Server.Client, resource: wayring.ObjectHandle, text: []const u8) !void {
    return client.postError(resource, @intFromEnum(generated.wl_subcompositor_types.@"error".bad_parent), text);
}

fn findSubsurface(self: *SubcompositorGlobal, surface: *CompositorGlobal.Surface) ?*Subsurface {
    for (self.subsurfaces.items) |subsurface| if (subsurface.node.surface == surface) return subsurface;
    return null;
}

fn effectiveSync(subsurface: *Subsurface) bool {
    if (subsurface.synchronized) return true;
    var parent = subsurface.node.parent;
    while (parent) |node| : (parent = node.parent) {
        if (subsurface.owner.findSubsurface(node.surface)) |ancestor| if (ancestor.synchronized) return true;
    }
    return false;
}

fn handleCommit(context: *anyopaque, commit_value: CompositorGlobal.Commit) !void {
    const self: *SubcompositorGlobal = @ptrCast(@alignCast(context));
    var commit = commit_value;
    var commit_owned = true;
    defer if (commit_owned) {
        commit.releaseBuffer() catch {};
        commit.deinit();
    };
    const node = self.tree.nodeFor(commit.surface) catch return error.OutOfMemory;
    var fragment: Fragment = .{ .allocator = self.allocator };
    var fragment_owned = true;
    defer if (fragment_owned) fragment.deinit();
    for (node.pending_children.items) |child| {
        const child_subsurface = self.findSubsurface(child.surface) orelse continue;
        if (child_subsurface.cached) |cached| {
            child_subsurface.cached = null;
            var source = cached;
            defer source.deinit();
            ignoreFifoWaits(&source);
            try appendFragment(&fragment, &source);
        }
    }
    commit_owned = false;
    try mergeEntry(&fragment, commit);
    try captureUpdate(self, node, &fragment);
    if (self.findSubsurface(commit.surface)) |subsurface| if (effectiveSync(subsurface)) {
        if (subsurface.cached) |cached| {
            subsurface.cached = null;
            var combined = cached;
            appendFragment(&combined, &fragment) catch |err| {
                combined.deinit();
                return err;
            };
            fragment.deinit();
            fragment = combined;
        }
        subsurface.cached = fragment;
        fragment_owned = false;
        return;
    };
    fragment_owned = false;
    try emit(self, SurfaceTree.root(node), fragment);
}

fn appendFragment(destination: *Fragment, source: *Fragment) !void {
    try destination.entries.ensureUnusedCapacity(destination.allocator, source.entries.items.len);
    try destination.updates.ensureUnusedCapacity(destination.allocator, source.updates.items.len);
    while (source.entries.items.len != 0) {
        const commit = source.entries.orderedRemove(0);
        try mergeEntry(destination, commit);
    }
    destination.updates.appendSliceAssumeCapacity(source.updates.items);
    source.updates.clearRetainingCapacity();
}

fn mergeEntry(fragment: *Fragment, commit: CompositorGlobal.Commit) !void {
    for (fragment.entries.items) |*old| if (old.surface == commit.surface) {
        return mergeCommit(old, commit);
    };
    fragment.entries.append(fragment.allocator, commit) catch |err| {
        var rejected = commit;
        rejected.releaseBuffer() catch {};
        rejected.deinit();
        return err;
    };
}

fn mergeCommit(old: *CompositorGlobal.Commit, commit_value: CompositorGlobal.Commit) !void {
    var newest = commit_value;
    var newest_owned = true;
    errdefer if (newest_owned) {
        newest.releaseBuffer() catch {};
        newest.deinit();
    };
    const allocator = old.allocator;
    const fifo_set = old.fifo_set or newest.fifo_set;
    const fifo_wait = old.fifo_wait or newest.fifo_wait;
    const target_timestamp = if (old.target_timestamp) |old_target|
        if (newest.target_timestamp) |newest_target| @max(old_target, newest_target) else old_target
    else
        newest.target_timestamp;
    const callbacks = try allocator.alloc(wayring.ObjectHandle, old.frame_callbacks.len + newest.frame_callbacks.len);
    errdefer allocator.free(callbacks);
    const surface_damage = try allocator.alloc(@TypeOf(newest.surface_damage[0]), old.surface_damage.len + newest.surface_damage.len);
    errdefer allocator.free(surface_damage);
    const buffer_damage = try allocator.alloc(@TypeOf(newest.buffer_damage[0]), old.buffer_damage.len + newest.buffer_damage.len);
    errdefer allocator.free(buffer_damage);
    @memcpy(callbacks[0..old.frame_callbacks.len], old.frame_callbacks);
    @memcpy(callbacks[old.frame_callbacks.len..], newest.frame_callbacks);
    @memcpy(surface_damage[0..old.surface_damage.len], old.surface_damage);
    @memcpy(surface_damage[old.surface_damage.len..], newest.surface_damage);
    @memcpy(buffer_damage[0..old.buffer_damage.len], old.buffer_damage);
    @memcpy(buffer_damage[old.buffer_damage.len..], newest.buffer_damage);
    allocator.free(newest.frame_callbacks);
    allocator.free(newest.surface_damage);
    allocator.free(newest.buffer_damage);
    newest.frame_callbacks = callbacks;
    newest.surface_damage = surface_damage;
    newest.buffer_damage = buffer_damage;
    if (newest.attachment == .unchanged) {
        newest.attachment = old.attachment;
        old.attachment = .unchanged;
        newest.synchronization = old.synchronization;
        old.synchronization = null;
    } else {
        old.releaseBuffer() catch {};
    }
    old.deinit();
    old.* = newest;
    // Synchronized commits collapse into one absolute state update. FIFO
    // actions accumulate, while timestamps retain the latest deadline needed
    // to preserve receipt order. A parent boundary ignores only FIFO waits.
    old.fifo_set = fifo_set;
    old.fifo_wait = fifo_wait;
    old.target_timestamp = target_timestamp;
    newest_owned = false;
}

fn ignoreFifoWaits(fragment: *Fragment) void {
    for (fragment.entries.items) |*entry| entry.fifo_wait = false;
}

fn captureUpdate(self: *SubcompositorGlobal, node: *SurfaceTree.Node, fragment: *Fragment) !void {
    if (node.pending_children.items.len == 0 and node.current_children.items.len == 0) return;
    const update_ptr = try self.allocator.create(OwnedUpdate);
    errdefer self.allocator.destroy(update_ptr);
    update_ptr.* = .{ .allocator = self.allocator, .update = try self.tree.capture(node) };
    errdefer update_ptr.update.deinit();
    try fragment.updates.append(self.allocator, .{ .context = update_ptr, .apply = applyUpdate, .deinit = deinitUpdate });
}

fn emit(self: *SubcompositorGlobal, root_node: *SurfaceTree.Node, fragment_value: Fragment) !void {
    var fragment = fragment_value;
    errdefer fragment.deinit();
    const entries = try fragment.entries.toOwnedSlice(self.allocator);
    fragment.entries = .empty;
    var entries_owned = true;
    errdefer if (entries_owned) {
        for (entries) |*commit| {
            commit.releaseBuffer() catch {};
            commit.deinit();
        }
        self.allocator.free(entries);
    };
    const updates = try fragment.updates.toOwnedSlice(self.allocator);
    fragment.updates = .empty;
    var updates_owned = true;
    errdefer if (updates_owned) {
        for (updates) |update| update.deinit(update.context);
        self.allocator.free(updates);
    };
    var transaction = try CompositorGlobal.Transaction.init(self.allocator, root_node.surface, entries, updates);
    entries_owned = false;
    updates_owned = false;
    errdefer transaction.deinit();
    try self.compositor.enqueueTransaction(transaction);
}

fn flush(self: *SubcompositorGlobal, node: *SurfaceTree.Node) !void {
    const subsurface = self.findSubsurface(node.surface) orelse return;
    const fragment = subsurface.cached orelse return;
    subsurface.cached = null;
    try emit(self, SurfaceTree.root(node), fragment);
}

fn flushNewlyDesynchronized(self: *SubcompositorGlobal, node: *SurfaceTree.Node) !void {
    if (self.findSubsurface(node.surface)) |subsurface| {
        if (!effectiveSync(subsurface) and subsurface.cached != null) try flush(self, node);
    }
    for (node.pending_children.items) |child| try flushNewlyDesynchronized(self, child);
}

fn applyUpdate(context: *anyopaque) void {
    const owned: *OwnedUpdate = @ptrCast(@alignCast(context));
    owned.update.apply();
}
fn deinitUpdate(context: *anyopaque) void {
    const owned: *OwnedUpdate = @ptrCast(@alignCast(context));
    owned.update.deinit();
    const allocator = owned.allocator;
    allocator.destroy(owned);
}

fn surfaceDestroyed(context: *anyopaque, surface: *CompositorGlobal.Surface) void {
    const self: *SubcompositorGlobal = @ptrCast(@alignCast(context));
    const node = self.tree.find(surface) orelse return;
    deactivateSubtree(self, node);
    self.tree.detach(node);
}

fn deactivateSubtree(self: *SubcompositorGlobal, node: *SurfaceTree.Node) void {
    if (self.findSubsurface(node.surface)) |subsurface| {
        subsurface.inert = true;
        if (subsurface.cached) |*fragment| {
            fragment.deinit();
            subsurface.cached = null;
        }
    }
    for (node.pending_children.items) |child| deactivateSubtree(self, child);
    for (node.current_children.items) |child| {
        if (std.mem.indexOfScalar(*SurfaceTree.Node, node.pending_children.items, child) == null)
            deactivateSubtree(self, child);
    }
}

fn childRoleDestroyed(context: *anyopaque) void {
    const subsurface: *Subsurface = @ptrCast(@alignCast(context));
    subsurface.inert = true;
    subsurface.owner.tree.detach(subsurface.node);
}

fn destroySubsurface(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const subsurface: *Subsurface = @ptrCast(@alignCast(context));
    const owner = subsurface.owner;
    if (std.mem.indexOfScalar(*Subsurface, owner.subsurfaces.items, subsurface)) |index| _ = owner.subsurfaces.swapRemove(index);
    destroySubsurfaceValue(subsurface);
}

fn destroySubsurfaceValue(subsurface: *Subsurface) void {
    if (subsurface.cached) |*fragment| fragment.deinit();
    if (subsurface.node.surface.role_context == @as(*anyopaque, @ptrCast(subsurface)))
        subsurface.node.surface.clearRole(subsurface);
    subsurface.owner.tree.detach(subsurface.node);
    subsurface.owner.allocator.destroy(subsurface);
}

test "synchronized subsurfaces preserve nested parent commit boundaries" {
    const core = @import("wayring-core");
    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var tree = SurfaceTree.init(std.testing.allocator);
    defer tree.deinit();
    var subcompositor: SubcompositorGlobal = undefined;
    try subcompositor.init(std.testing.allocator, &server, &compositor, &tree);
    defer subcompositor.deinit();
    const client = try server.createClient();
    defer server.destroyClient(client) catch unreachable;

    var peer = wayring.Connection.init(
        std.testing.allocator,
        .client,
        wayring.default_max_frame_size,
    );
    defer peer.deinit();
    _ = try core.bootstrapDisplay(&peer);
    const registry: wayring.ObjectHandle = .{
        .id = 2,
        .generation = try core.getRegistry(&peer, 2),
    };
    try transferToServer(&peer, client);
    try transferFromServer(&peer, client);
    var compositor_name: u32 = 0;
    var subcompositor_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.wl_subcompositor.name))
            subcompositor_name = global.name;
    }
    const compositor_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            compositor_name,
            generated.wl_compositor.name,
            6,
            3,
            &generated.wl_compositor,
        ),
    };
    const subcompositor_resource: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            subcompositor_name,
            generated.wl_subcompositor.name,
            1,
            4,
            &generated.wl_subcompositor,
        ),
    };
    try transferToServer(&peer, client);

    const root_surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const child_surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const child_subsurface = try generated.wl_subcompositor_types.requests.get_subsurface(
        &peer,
        subcompositor_resource,
        child_surface,
        root_surface,
    );
    try transferToServer(&peer, client);
    const child = try CompositorGlobal.surfaceFor(client, child_surface);

    child.pending_fifo_set = true;
    child.pending_fifo_wait = true;
    child.pending_commit_timestamp = 50;
    const first_callback = try generated.wl_surface_types.requests.frame(&peer, child_surface);
    try generated.wl_surface_types.requests.commit(&peer, child_surface);
    try transferToServer(&peer, client);
    try std.testing.expect(compositor.popTransaction() == null);
    child.pending_commit_timestamp = 30;
    const second_callback = try generated.wl_surface_types.requests.frame(&peer, child_surface);
    try generated.wl_surface_types.requests.commit(&peer, child_surface);
    try generated.wl_subsurface_types.requests.set_position(&peer, child_subsurface, 7, 9);
    try transferToServer(&peer, client);
    try std.testing.expect(compositor.popTransaction() == null);

    try generated.wl_surface_types.requests.commit(&peer, root_surface);
    try transferToServer(&peer, client);
    var initial = compositor.popTransaction() orelse return error.MissingTransaction;
    defer initial.deinit();
    try std.testing.expectEqual(@as(usize, 2), initial.entries.len);
    const child_entry = transactionEntry(&initial, child_surface.id) orelse
        return error.MissingChildCommit;
    try std.testing.expectEqual(@as(usize, 2), child_entry.frame_callbacks.len);
    try std.testing.expectEqual(first_callback.id, child_entry.frame_callbacks[0].id);
    try std.testing.expectEqual(second_callback.id, child_entry.frame_callbacks[1].id);
    try std.testing.expect(child_entry.fifo_set);
    try std.testing.expect(!child_entry.fifo_wait);
    try std.testing.expectEqual(@as(?i96, 50), child_entry.target_timestamp);
    for (initial.hierarchy_updates) |update| update.apply(update.context);
    const child_node = tree.find(child_entry.surface) orelse return error.MissingChildNode;
    const root_node = tree.find(initial.root) orelse return error.MissingRootNode;
    try std.testing.expect(child_node.current_active);

    const grandchild_surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const grandchild_subsurface = try generated.wl_subcompositor_types.requests.get_subsurface(
        &peer,
        subcompositor_resource,
        grandchild_surface,
        child_surface,
    );
    try transferToServer(&peer, client);

    const grandchild_first = try generated.wl_surface_types.requests.frame(&peer, grandchild_surface);
    try generated.wl_surface_types.requests.commit(&peer, grandchild_surface);
    try transferToServer(&peer, client);
    try generated.wl_surface_types.requests.commit(&peer, child_surface);
    try transferToServer(&peer, client);
    const grandchild_second = try generated.wl_surface_types.requests.frame(&peer, grandchild_surface);
    try generated.wl_surface_types.requests.commit(&peer, grandchild_surface);
    try transferToServer(&peer, client);
    try std.testing.expect(compositor.popTransaction() == null);

    try generated.wl_surface_types.requests.commit(&peer, root_surface);
    try transferToServer(&peer, client);
    var first_boundary = compositor.popTransaction() orelse return error.MissingTransaction;
    defer first_boundary.deinit();
    try std.testing.expectEqual(@as(usize, 3), first_boundary.entries.len);
    const first_grandchild_entry = transactionEntry(&first_boundary, grandchild_surface.id) orelse
        return error.MissingGrandchildCommit;
    try std.testing.expectEqual(@as(usize, 1), first_grandchild_entry.frame_callbacks.len);
    try std.testing.expectEqual(grandchild_first.id, first_grandchild_entry.frame_callbacks[0].id);

    try generated.wl_surface_types.requests.commit(&peer, child_surface);
    try generated.wl_surface_types.requests.commit(&peer, root_surface);
    try transferToServer(&peer, client);
    var second_boundary = compositor.popTransaction() orelse return error.MissingTransaction;
    defer second_boundary.deinit();
    const second_grandchild_entry = transactionEntry(&second_boundary, grandchild_surface.id) orelse
        return error.MissingGrandchildCommit;
    try std.testing.expectEqual(@as(usize, 1), second_grandchild_entry.frame_callbacks.len);
    try std.testing.expectEqual(grandchild_second.id, second_grandchild_entry.frame_callbacks[0].id);

    try generated.wl_subsurface_types.requests.set_desync(&peer, grandchild_subsurface);
    child.pending_fifo_wait = true;
    child.pending_commit_timestamp = 75;
    try generated.wl_surface_types.requests.commit(&peer, child_surface);
    try generated.wl_surface_types.requests.commit(&peer, grandchild_surface);
    try transferToServer(&peer, client);
    try std.testing.expect(compositor.popTransaction() == null);
    try generated.wl_subsurface_types.requests.set_desync(&peer, child_subsurface);
    try transferToServer(&peer, client);
    var desynchronized = compositor.popTransaction() orelse return error.MissingTransaction;
    defer desynchronized.deinit();
    try std.testing.expectEqual(@as(usize, 1), desynchronized.entries.len);
    try std.testing.expectEqual(child_surface.id, desynchronized.entries[0].surface.resource.id);
    try std.testing.expect(desynchronized.entries[0].fifo_wait);
    try std.testing.expectEqual(@as(?i96, 75), desynchronized.entries[0].target_timestamp);
    var descendant_desynchronized = compositor.popTransaction() orelse return error.MissingTransaction;
    defer descendant_desynchronized.deinit();
    try std.testing.expectEqual(@as(usize, 1), descendant_desynchronized.entries.len);
    try std.testing.expectEqual(grandchild_surface.id, descendant_desynchronized.entries[0].surface.resource.id);

    try generated.wl_surface_types.requests.commit(&peer, root_surface);
    try transferToServer(&peer, client);
    var captured_before_destroy = compositor.popTransaction() orelse return error.MissingTransaction;
    defer captured_before_destroy.deinit();
    try std.testing.expect(captured_before_destroy.hierarchy_updates.len != 0);
    try generated.wl_subsurface_types.requests.destroy(&peer, child_subsurface);
    _ = try generated.wl_subcompositor_types.requests.get_subsurface(
        &peer,
        subcompositor_resource,
        child_surface,
        root_surface,
    );
    try transferToServer(&peer, client);
    for (captured_before_destroy.hierarchy_updates) |update| update.apply(update.context);
    try std.testing.expect(child_node.parent == root_node);
    try std.testing.expect(!child_node.current_active);
    try std.testing.expectEqual(SurfaceTree.Position{}, child_node.current_position);
    try std.testing.expect(std.mem.indexOfScalar(
        *SurfaceTree.Node,
        root_node.current_children.items,
        child_node,
    ) == null);
}

fn transactionEntry(
    transaction: *CompositorGlobal.Transaction,
    surface_id: u32,
) ?*CompositorGlobal.Commit {
    for (transaction.entries) |*commit| {
        if (commit.surface.resource.id == surface_id) return commit;
    }
    return null;
}

fn transferToServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (connection.nextBatch()) |batch| {
        try client.receive(batch.bytes, batch.fds);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
}

fn transferFromServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (client.connection.nextBatch()) |batch| {
        try connection.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}
