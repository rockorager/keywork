//! wl_subcompositor and synchronized subsurface state.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const slot_map = @import("../slot_map.zig");
const Surface = @import("surface.zig");

const wl = wayland.server.wl;

allocator: std.mem.Allocator,
global: *wl.Global,
surface_store: *Surface.Store,
subsurfaces: Store,
by_surface: std.AutoHashMapUnmanaged(Surface.Id, Id),
adapters: std.AutoHashMapUnmanaged(Id, *SubsurfaceResource),
parents: std.AutoHashMapUnmanaged(Surface.Id, *Parent),
repaint_listener: ?RepaintListener,

pub const Store = slot_map.SlotMap(State, enum { subsurface });
pub const Id = Store.Id;

pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const TreeBounds = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const RepaintListener = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque) void,
    surface_changed: *const fn (*anyopaque, Surface.Id) void,
};

pub const StackEntry = union(enum) {
    parent: void,
    child: struct {
        surface_id: Surface.Id,
        position: Point,
    },
};

pub const StackIterator = struct {
    shell: *Self,
    parent: ?*Parent,
    index: usize = 0,

    pub fn next(self: *StackIterator) ?StackEntry {
        const parent = self.parent orelse {
            if (self.index != 0) return null;
            self.index = 1;
            return .{ .parent = {} };
        };
        while (self.index < parent.current.items.len) {
            const node = parent.current.items[self.index];
            self.index += 1;
            switch (node) {
                .parent => return .{ .parent = {} },
                .child => |id| {
                    const state = self.shell.subsurfaces.get(id) orelse continue;
                    if (!state.active) continue;
                    return .{ .child = .{
                        .surface_id = state.surface_id,
                        .position = state.current_position,
                    } };
                },
            }
        }
        return null;
    }
};

pub const ReverseStackIterator = struct {
    shell: *Self,
    parent: ?*Parent,
    index: usize,

    pub fn next(self: *ReverseStackIterator) ?StackEntry {
        const parent = self.parent orelse {
            if (self.index == 0) return null;
            self.index = 0;
            return .{ .parent = {} };
        };
        while (self.index > 0) {
            self.index -= 1;
            const node = parent.current.items[self.index];
            switch (node) {
                .parent => return .{ .parent = {} },
                .child => |id| {
                    const state = self.shell.subsurfaces.get(id) orelse continue;
                    if (!state.active) continue;
                    return .{ .child = .{
                        .surface_id = state.surface_id,
                        .position = state.current_position,
                    } };
                },
            }
        }
        return null;
    }
};

pub const State = struct {
    surface_id: Surface.Id,
    parent_id: Surface.Id,
    pending_position: Point = .{},
    current_position: Point = .{},
    synchronized: bool = true,
    active: bool = false,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    surface_store: *Surface.Store,
) !void {
    self.* = .{
        .allocator = allocator,
        .global = undefined,
        .surface_store = surface_store,
        .subsurfaces = .{},
        .by_surface = .empty,
        .adapters = .empty,
        .parents = .empty,
        .repaint_listener = null,
    };
    errdefer self.subsurfaces.deinit(allocator);
    errdefer self.by_surface.deinit(allocator);
    errdefer self.adapters.deinit(allocator);
    errdefer self.parents.deinit(allocator);
    self.global = try wl.Global.create(display, wl.Subcompositor, 1, *Self, self, bind);
}

pub fn deinit(self: *Self) void {
    self.global.destroy();
    std.debug.assert(self.parents.count() == 0);
    std.debug.assert(self.by_surface.count() == 0);
    std.debug.assert(self.adapters.count() == 0);
    self.parents.deinit(self.allocator);
    self.by_surface.deinit(self.allocator);
    self.adapters.deinit(self.allocator);
    self.subsurfaces.deinit(self.allocator);
    self.* = undefined;
}

pub fn setRepaintListener(self: *Self, listener: RepaintListener) void {
    std.debug.assert(self.repaint_listener == null);
    self.repaint_listener = listener;
}

pub fn clearRepaintListener(self: *Self) void {
    std.debug.assert(self.repaint_listener != null);
    self.repaint_listener = null;
}

pub fn stackIterator(self: *Self, surface_id: Surface.Id) StackIterator {
    return .{
        .shell = self,
        .parent = self.parents.get(surface_id),
    };
}

pub fn reverseStackIterator(self: *Self, surface_id: Surface.Id) ReverseStackIterator {
    const parent = self.parents.get(surface_id);
    return .{
        .shell = self,
        .parent = parent,
        .index = if (parent) |value| value.current.items.len else 1,
    };
}

pub fn rootSurface(self: *Self, surface_id: Surface.Id) Surface.Id {
    var root = surface_id;
    while (self.by_surface.get(root)) |id| {
        const state = self.subsurfaces.get(id) orelse break;
        root = state.parent_id;
    }
    return root;
}

pub fn surfaceOffset(self: *Self, surface_id: Surface.Id) Point {
    var offset: Point = .{};
    var current = surface_id;
    while (self.by_surface.get(current)) |id| {
        const state = self.subsurfaces.get(id) orelse break;
        offset.x +|= state.current_position.x;
        offset.y +|= state.current_position.y;
        current = state.parent_id;
    }
    return offset;
}

pub fn treeBounds(self: *Self, surface_id: Surface.Id) ?TreeBounds {
    var bounds: ?AccumulatedBounds = null;
    self.addTreeBounds(surface_id, 0, 0, &bounds);
    const result = bounds orelse return null;
    const width = result.right - result.left;
    const height = result.bottom - result.top;
    if (result.left < std.math.minInt(i32) or result.left > std.math.maxInt(i32) or
        result.top < std.math.minInt(i32) or result.top > std.math.maxInt(i32) or
        width <= 0 or width > std.math.maxInt(u32) or
        height <= 0 or height > std.math.maxInt(u32)) return null;
    return .{
        .x = @intCast(result.left),
        .y = @intCast(result.top),
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

const AccumulatedBounds = struct {
    left: i64,
    top: i64,
    right: i64,
    bottom: i64,
};

fn addTreeBounds(
    self: *Self,
    surface_id: Surface.Id,
    x: i64,
    y: i64,
    bounds: *?AccumulatedBounds,
) void {
    const buffer = Surface.currentBuffer(self.surface_store, surface_id) orelse return;
    const surface_bounds: AccumulatedBounds = .{
        .left = x,
        .top = y,
        .right = x + buffer.logical_size.width,
        .bottom = y + buffer.logical_size.height,
    };
    bounds.* = if (bounds.*) |current| .{
        .left = @min(current.left, surface_bounds.left),
        .top = @min(current.top, surface_bounds.top),
        .right = @max(current.right, surface_bounds.right),
        .bottom = @max(current.bottom, surface_bounds.bottom),
    } else surface_bounds;

    var stack = self.stackIterator(surface_id);
    while (stack.next()) |entry| switch (entry) {
        .parent => {},
        .child => |child| self.addTreeBounds(
            child.surface_id,
            x + child.position.x,
            y + child.position.y,
            bounds,
        ),
    };
}

fn requestRepaint(self: *Self) void {
    if (self.repaint_listener) |listener| listener.request(listener.context);
}

fn bind(client: *wl.Client, self: *Self, version: u32, id: u32) void {
    const resource = wl.Subcompositor.create(client, version, id) catch {
        client.postNoMemory();
        return;
    };
    resource.setHandler(*Self, handleRequest, null, self);
}

fn handleRequest(
    resource: *wl.Subcompositor,
    request: wl.Subcompositor.Request,
    self: *Self,
) void {
    switch (request) {
        .destroy => resource.destroy(),
        .get_subsurface => |get| SubsurfaceResource.create(
            self,
            resource.getClient(),
            resource.getVersion(),
            get.id,
            Surface.fromResource(get.surface),
            Surface.fromResource(get.parent),
        ) catch |err| switch (err) {
            error.BadSurface => resource.postError(
                .bad_surface,
                "wl_surface already has another role or subsurface object",
            ),
            error.BadParent => resource.postError(
                .bad_parent,
                "subsurface parent would create a cycle",
            ),
            error.OutOfMemory, error.ResourceCreateFailed => resource.postNoMemory(),
        },
    }
}

fn effectivelySynchronized(self: *Self, id: Id) bool {
    const state = self.subsurfaces.get(id) orelse return false;
    if (state.synchronized) return true;
    const parent_subsurface = self.by_surface.get(state.parent_id) orelse return false;
    return self.effectivelySynchronized(parent_subsurface);
}

fn nodesEqual(first: Parent.Node, second: Parent.Node) bool {
    return switch (first) {
        .parent => second == .parent,
        .child => |first_id| switch (second) {
            .parent => false,
            .child => |second_id| std.meta.eql(first_id, second_id),
        },
    };
}

fn nodeMatchesCommit(current: Parent.Node, committed: Parent.CommitNode) bool {
    return switch (current) {
        .parent => committed == .parent,
        .child => |current_id| switch (committed) {
            .parent => false,
            .child => |child| std.meta.eql(current_id, child.id),
        },
    };
}

fn applyParent(self: *Self, parent: *Parent) void {
    if (parent.surface == null) return;
    if (parent.commits.items.len == 0) {
        self.applyLiveParentState(parent);
        return;
    }
    var commit = parent.commits.orderedRemove(0);
    defer commit.deinit(parent.allocator);
    var visual_state_changed = parent.current.items.len != commit.nodes.len;
    if (!visual_state_changed) {
        for (parent.current.items, commit.nodes) |current, committed| {
            if (nodeMatchesCommit(current, committed)) continue;
            visual_state_changed = true;
            break;
        }
    }
    parent.current.clearRetainingCapacity();
    for (commit.nodes) |node| parent.current.appendAssumeCapacity(switch (node) {
        .parent => .{ .parent = {} },
        .child => |child| .{ .child = child.id },
    });

    for (commit.nodes) |node| switch (node) {
        .parent => {},
        .child => |child| {
            const state = self.subsurfaces.get(child.id) orelse continue;
            if (state.active and !std.meta.eql(state.current_position, child.position)) {
                visual_state_changed = true;
            }
            state.current_position = child.position;
            state.active = true;
        },
    };

    for (commit.nodes) |node| switch (node) {
        .parent => {},
        .child => |child| {
            const sequence = child.cached_sequence orelse continue;
            const adapter = self.adapters.get(child.id) orelse continue;
            const surface = adapter.surface orelse continue;
            surface.applyCachedUpTo(sequence);
        },
    };
    if (visual_state_changed) self.requestRepaint();
}

fn applyLiveParentState(self: *Self, parent: *Parent) void {
    var visual_state_changed = parent.current.items.len != parent.pending.items.len;
    if (!visual_state_changed) {
        for (parent.current.items, parent.pending.items) |current, pending| {
            if (nodesEqual(current, pending)) continue;
            visual_state_changed = true;
            break;
        }
    }
    parent.current.clearRetainingCapacity();
    parent.current.appendSliceAssumeCapacity(parent.pending.items);

    for (parent.current.items) |node| switch (node) {
        .parent => {},
        .child => |id| {
            const state = self.subsurfaces.get(id) orelse continue;
            if (state.active and !std.meta.eql(state.current_position, state.pending_position)) {
                visual_state_changed = true;
            }
            state.current_position = state.pending_position;
            state.active = true;
        },
    };

    for (parent.current.items) |node| switch (node) {
        .parent => {},
        .child => |id| {
            if (!self.effectivelySynchronized(id)) continue;
            const adapter = self.adapters.get(id) orelse continue;
            const surface = adapter.surface orelse continue;
            surface.applyCachedUpTo(std.math.maxInt(u64));
        },
    };
    if (visual_state_changed) self.requestRepaint();
}

fn flushDesynchronizedDescendants(self: *Self, parent_id: Surface.Id) void {
    const parent = self.parents.get(parent_id) orelse return;
    for (parent.pending.items) |node| switch (node) {
        .parent => {},
        .child => |id| {
            if (self.effectivelySynchronized(id)) continue;
            const adapter = self.adapters.get(id) orelse continue;
            const surface = adapter.surface orelse continue;
            if (surface.hasCachedCommit()) surface.applyCachedCommit();
            self.flushDesynchronizedDescendants(surface.handle());
        },
    };
}

const Parent = struct {
    const Node = union(enum) {
        parent: void,
        child: Id,
    };

    const CommitNode = union(enum) {
        parent: void,
        child: struct {
            id: Id,
            position: Point,
            cached_sequence: ?u64,
        },
    };

    const Commit = struct {
        nodes: []CommitNode,

        fn deinit(self: *Commit, allocator: std.mem.Allocator) void {
            allocator.free(self.nodes);
            self.* = undefined;
        }
    };

    allocator: std.mem.Allocator,
    shell: *Self,
    surface_id: Surface.Id,
    surface: ?*Surface,
    listener: Surface.CommitListener,
    pending: std.ArrayList(Node),
    current: std.ArrayList(Node),
    commits: std.ArrayList(Commit),
    child_count: usize,

    fn create(shell: *Self, surface: *Surface) error{OutOfMemory}!*Parent {
        const self = shell.allocator.create(Parent) catch return error.OutOfMemory;
        errdefer shell.allocator.destroy(self);

        self.* = .{
            .allocator = shell.allocator,
            .shell = shell,
            .surface_id = surface.handle(),
            .surface = surface,
            .listener = undefined,
            .pending = .empty,
            .current = .empty,
            .commits = .empty,
            .child_count = 0,
        };
        errdefer self.pending.deinit(shell.allocator);
        errdefer self.current.deinit(shell.allocator);
        errdefer self.commits.deinit(shell.allocator);
        try self.pending.append(shell.allocator, .{ .parent = {} });
        try self.current.append(shell.allocator, .{ .parent = {} });

        self.listener = .{
            .context = self,
            .committed = handleCommitted,
            .discarded = handleDiscarded,
            .applied = handleApplied,
            .surface_destroyed = handleSurfaceDestroyed,
        };
        try surface.addCommitListener(&self.listener);
        errdefer surface.removeCommitListener(&self.listener);
        shell.parents.put(shell.allocator, self.surface_id, self) catch
            return error.OutOfMemory;
        return self;
    }

    fn destroy(self: *Parent) void {
        std.debug.assert(self.child_count == 0);
        if (self.surface) |surface| {
            surface.removeCommitListener(&self.listener);
            _ = self.shell.parents.remove(self.surface_id);
        }
        self.pending.deinit(self.allocator);
        self.current.deinit(self.allocator);
        self.clearCommits();
        self.commits.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn captureCommit(self: *Parent) error{OutOfMemory}!void {
        const nodes = try self.allocator.alloc(CommitNode, self.pending.items.len);
        errdefer self.allocator.free(nodes);
        for (self.pending.items, nodes) |node, *destination| destination.* = switch (node) {
            .parent => .{ .parent = {} },
            .child => |id| child: {
                const state = self.shell.subsurfaces.get(id) orelse break :child .{ .child = .{
                    .id = id,
                    .position = .{},
                    .cached_sequence = null,
                } };
                const sequence = if (self.shell.effectivelySynchronized(id)) sequence: {
                    const adapter = self.shell.adapters.get(id) orelse break :sequence null;
                    const surface = adapter.surface orelse break :sequence null;
                    break :sequence surface.latestCachedSequence();
                } else null;
                break :child .{ .child = .{
                    .id = id,
                    .position = state.pending_position,
                    .cached_sequence = sequence,
                } };
            },
        };
        try self.commits.append(self.allocator, .{ .nodes = nodes });
    }

    fn clearCommits(self: *Parent) void {
        for (self.commits.items) |*commit| commit.deinit(self.allocator);
        self.commits.clearRetainingCapacity();
    }

    fn addChild(self: *Parent, id: Id) error{OutOfMemory}!void {
        try self.pending.append(self.allocator, .{ .child = id });
        errdefer _ = self.pending.pop();
        try self.current.ensureTotalCapacity(self.allocator, self.pending.items.len);
        self.child_count += 1;
    }

    fn removeChild(self: *Parent, id: Id) void {
        removeNode(&self.pending, id);
        removeNode(&self.current, id);
        std.debug.assert(self.child_count > 0);
        self.child_count -= 1;
    }

    fn place(
        self: *Parent,
        child_id: Id,
        sibling_id: Surface.Id,
        above: bool,
    ) error{ BadSurface, OutOfMemory }!void {
        const child_index = findChild(self.pending.items, child_id) orelse
            return error.BadSurface;
        const sibling_index = self.findSurface(sibling_id) orelse
            return error.BadSurface;
        if (child_index == sibling_index) return error.BadSurface;

        const node = self.pending.orderedRemove(child_index);
        const reference_index = self.findSurface(sibling_id) orelse unreachable;
        const insertion_index = reference_index + @intFromBool(above);
        self.pending.insert(self.allocator, insertion_index, node) catch {
            self.pending.insertAssumeCapacity(child_index, node);
            return error.OutOfMemory;
        };
        try self.current.ensureTotalCapacity(self.allocator, self.pending.items.len);
    }

    fn findSurface(self: *const Parent, surface_id: Surface.Id) ?usize {
        if (std.meta.eql(surface_id, self.surface_id)) {
            for (self.pending.items, 0..) |node, index| switch (node) {
                .parent => return index,
                .child => {},
            };
        }
        const subsurface_id = self.shell.by_surface.get(surface_id) orelse return null;
        return findChild(self.pending.items, subsurface_id);
    }

    fn findChild(nodes: []const Node, id: Id) ?usize {
        for (nodes, 0..) |node, index| switch (node) {
            .parent => {},
            .child => |candidate| if (std.meta.eql(candidate, id)) return index,
        };
        return null;
    }

    fn removeNode(nodes: *std.ArrayList(Node), id: Id) void {
        const index = findChild(nodes.items, id) orelse return;
        _ = nodes.orderedRemove(index);
    }

    fn handleApplied(context: *anyopaque) void {
        const self: *Parent = @ptrCast(@alignCast(context));
        self.shell.applyParent(self);
    }

    fn handleCommitted(context: *anyopaque) void {
        const self: *Parent = @ptrCast(@alignCast(context));
        self.captureCommit() catch {
            if (self.surface) |surface| surface.waylandResource().postNoMemory();
        };
    }

    fn handleDiscarded(context: *anyopaque) void {
        const self: *Parent = @ptrCast(@alignCast(context));
        self.clearCommits();
    }

    fn handleSurfaceDestroyed(context: *anyopaque) void {
        const self: *Parent = @ptrCast(@alignCast(context));
        const surface = self.surface orelse return;
        surface.removeCommitListener(&self.listener);
        _ = self.shell.parents.remove(self.surface_id);
        self.surface = null;
        for (self.pending.items) |node| switch (node) {
            .parent => {},
            .child => |id| {
                if (self.shell.subsurfaces.get(id)) |state| state.active = false;
            },
        };
    }
};

fn getParent(self: *Self, surface: *Surface) error{OutOfMemory}!*Parent {
    return self.parents.get(surface.handle()) orelse try Parent.create(self, surface);
}

fn releaseParent(parent: *Parent) void {
    if (parent.child_count == 0) parent.destroy();
}

const SubsurfaceResource = struct {
    allocator: std.mem.Allocator,
    shell: *Self,
    id: Id,
    resource: *wl.Subsurface,
    surface: ?*Surface,
    parent: ?*Parent,

    const CreateError = error{
        OutOfMemory,
        ResourceCreateFailed,
        BadSurface,
        BadParent,
    };

    fn create(
        shell: *Self,
        client: *wl.Client,
        version: u32,
        protocol_id: u32,
        surface: *Surface,
        parent_surface: *Surface,
    ) CreateError!void {
        if (shell.by_surface.contains(surface.handle())) return error.BadSurface;
        if (surface.assignedRole()) |role| {
            if (role != .subsurface) return error.BadSurface;
        }
        var ancestor = parent_surface.handle();
        while (true) {
            if (std.meta.eql(ancestor, surface.handle())) return error.BadParent;
            const ancestor_id = shell.by_surface.get(ancestor) orelse break;
            const ancestor_state = shell.subsurfaces.get(ancestor_id) orelse break;
            ancestor = ancestor_state.parent_id;
        }

        const resource = try wl.Subsurface.create(client, version, protocol_id);
        errdefer resource.destroy();
        const self = shell.allocator.create(SubsurfaceResource) catch
            return error.OutOfMemory;
        errdefer shell.allocator.destroy(self);

        const id = shell.subsurfaces.insert(shell.allocator, .{
            .surface_id = surface.handle(),
            .parent_id = parent_surface.handle(),
        }) catch return error.OutOfMemory;
        errdefer _ = shell.subsurfaces.remove(id);

        self.* = .{
            .allocator = shell.allocator,
            .shell = shell,
            .id = id,
            .resource = resource,
            .surface = surface,
            .parent = null,
        };

        surface.reserveRole(.subsurface, .{
            .context = self,
            .before_commit = beforeSurfaceCommit,
            .after_commit = afterSurfaceCommit,
            .surface_destroyed = surfaceDestroyed,
        }) catch return error.BadSurface;
        errdefer surface.releaseRole(self);

        const parent = try shell.getParent(parent_surface);
        var child_added = false;
        errdefer if (child_added) {
            parent.removeChild(id);
            releaseParent(parent);
        } else {
            releaseParent(parent);
        };
        try parent.addChild(id);
        child_added = true;
        self.parent = parent;

        shell.by_surface.put(shell.allocator, surface.handle(), id) catch
            return error.OutOfMemory;
        errdefer _ = shell.by_surface.remove(surface.handle());
        shell.adapters.put(shell.allocator, id, self) catch return error.OutOfMemory;

        surface.assignReservedRole(.subsurface, self) catch unreachable;
        resource.setHandler(
            *SubsurfaceResource,
            SubsurfaceResource.handleRequest,
            SubsurfaceResource.handleDestroy,
            self,
        );
    }

    fn handleRequest(
        resource: *wl.Subsurface,
        request: wl.Subsurface.Request,
        self: *SubsurfaceResource,
    ) void {
        switch (request) {
            .destroy => resource.destroy(),
            else => {
                const state = self.shell.subsurfaces.get(self.id) orelse return;
                const parent = self.parent orelse return;
                if (parent.surface == null) return;

                switch (request) {
                    .destroy => unreachable,
                    .set_position => |position| state.pending_position = .{
                        .x = position.x,
                        .y = position.y,
                    },
                    .place_above => |place| parent.place(
                        self.id,
                        Surface.fromResource(place.sibling).handle(),
                        true,
                    ) catch |err| switch (err) {
                        error.BadSurface => resource.postError(
                            .bad_surface,
                            "reference is not the parent or a sibling",
                        ),
                        error.OutOfMemory => resource.postNoMemory(),
                    },
                    .place_below => |place| parent.place(
                        self.id,
                        Surface.fromResource(place.sibling).handle(),
                        false,
                    ) catch |err| switch (err) {
                        error.BadSurface => resource.postError(
                            .bad_surface,
                            "reference is not the parent or a sibling",
                        ),
                        error.OutOfMemory => resource.postNoMemory(),
                    },
                    .set_sync => state.synchronized = true,
                    .set_desync => {
                        state.synchronized = false;
                        if (!self.shell.effectivelySynchronized(self.id)) {
                            if (self.surface) |surface| {
                                if (surface.hasCachedCommit()) surface.applyCachedCommit();
                                self.shell.flushDesynchronizedDescendants(surface.handle());
                            }
                        }
                    },
                }
            },
        }
    }

    fn handleDestroy(_: *wl.Subsurface, self: *SubsurfaceResource) void {
        const was_active = if (self.shell.subsurfaces.get(self.id)) |state|
            state.active
        else
            false;
        if (self.surface) |surface| {
            surface.discardCachedCommit();
            surface.releaseRole(self);
            _ = self.shell.by_surface.remove(surface.handle());
        }
        self.detach();
        _ = self.shell.adapters.remove(self.id);
        _ = self.shell.subsurfaces.remove(self.id);
        if (was_active) self.shell.requestRepaint();
        self.allocator.destroy(self);
    }

    fn detach(self: *SubsurfaceResource) void {
        const parent = self.parent orelse return;
        parent.removeChild(self.id);
        self.parent = null;
        releaseParent(parent);
    }

    fn beforeSurfaceCommit(
        context: *anyopaque,
        _: Surface.CommitInfo,
    ) Surface.CommitAction {
        const self: *SubsurfaceResource = @ptrCast(@alignCast(context));
        if (self.shell.effectivelySynchronized(self.id)) return .cache;
        const surface = self.surface orelse return .reject;
        return if (surface.hasCachedCommit()) .apply_cached else .apply;
    }

    fn afterSurfaceCommit(context: *anyopaque, _: Surface.CommitInfo) void {
        const self: *SubsurfaceResource = @ptrCast(@alignCast(context));
        const surface = self.surface orelse return;
        if (self.shell.repaint_listener) |listener| {
            listener.surface_changed(listener.context, surface.handle());
        }
    }

    fn surfaceDestroyed(context: *anyopaque) void {
        const self: *SubsurfaceResource = @ptrCast(@alignCast(context));
        const was_active = if (self.shell.subsurfaces.get(self.id)) |state|
            state.active
        else
            false;
        if (self.surface) |surface| _ = self.shell.by_surface.remove(surface.handle());
        self.surface = null;
        self.detach();
        _ = self.shell.subsurfaces.remove(self.id);
        if (was_active) self.shell.requestRepaint();
    }
};

test "subsurface points support negative positions" {
    const point: Point = .{ .x = -20, .y = 15 };
    try std.testing.expectEqual(@as(i32, -20), point.x);
    try std.testing.expectEqual(@as(i32, 15), point.y);
}

test "stack iterator preserves children below and above their parent" {
    var shell: Self = undefined;
    shell.subsurfaces = .{};
    defer shell.subsurfaces.deinit(std.testing.allocator);

    const parent_surface: Surface.Id = .{ .index = 10, .generation = 1 };
    const below_surface: Surface.Id = .{ .index = 11, .generation = 1 };
    const above_surface: Surface.Id = .{ .index = 12, .generation = 1 };
    const below = try shell.subsurfaces.insert(std.testing.allocator, .{
        .surface_id = below_surface,
        .parent_id = parent_surface,
        .current_position = .{ .x = -2, .y = 3 },
        .active = true,
    });
    defer _ = shell.subsurfaces.remove(below);
    const above = try shell.subsurfaces.insert(std.testing.allocator, .{
        .surface_id = above_surface,
        .parent_id = parent_surface,
        .current_position = .{ .x = 5, .y = 7 },
        .active = true,
    });
    defer _ = shell.subsurfaces.remove(above);

    var parent: Parent = undefined;
    parent.current = .empty;
    defer parent.current.deinit(std.testing.allocator);
    try parent.current.append(std.testing.allocator, .{ .child = below });
    try parent.current.append(std.testing.allocator, .{ .parent = {} });
    try parent.current.append(std.testing.allocator, .{ .child = above });

    var iterator_value: StackIterator = .{
        .shell = &shell,
        .parent = &parent,
    };
    const below_entry = iterator_value.next().?;
    try std.testing.expect(std.meta.eql(below_surface, below_entry.child.surface_id));
    try std.testing.expectEqual(Point{ .x = -2, .y = 3 }, below_entry.child.position);
    try std.testing.expect(iterator_value.next().? == .parent);
    const above_entry = iterator_value.next().?;
    try std.testing.expect(std.meta.eql(above_surface, above_entry.child.surface_id));
    try std.testing.expectEqual(Point{ .x = 5, .y = 7 }, above_entry.child.position);
    try std.testing.expectEqual(@as(?StackEntry, null), iterator_value.next());

    var reverse_iterator: ReverseStackIterator = .{
        .shell = &shell,
        .parent = &parent,
        .index = parent.current.items.len,
    };
    const reverse_above = reverse_iterator.next().?;
    try std.testing.expect(std.meta.eql(above_surface, reverse_above.child.surface_id));
    try std.testing.expect(reverse_iterator.next().? == .parent);
    const reverse_below = reverse_iterator.next().?;
    try std.testing.expect(std.meta.eql(below_surface, reverse_below.child.surface_id));
    try std.testing.expectEqual(@as(?StackEntry, null), reverse_iterator.next());
}

test "applying changed subsurface parent state requests one repaint" {
    var shell: Self = undefined;
    shell.subsurfaces = .{};
    defer shell.subsurfaces.deinit(std.testing.allocator);
    shell.adapters = .empty;
    defer shell.adapters.deinit(std.testing.allocator);

    const parent_surface: Surface.Id = .{ .index = 10, .generation = 1 };
    const child_surface: Surface.Id = .{ .index = 11, .generation = 1 };
    const child = try shell.subsurfaces.insert(std.testing.allocator, .{
        .surface_id = child_surface,
        .parent_id = parent_surface,
        .pending_position = .{ .x = 8, .y = 12 },
        .current_position = .{ .x = 2, .y = 3 },
        .active = true,
    });
    defer _ = shell.subsurfaces.remove(child);

    var repaint_count: usize = 0;
    shell.repaint_listener = .{
        .context = &repaint_count,
        .request = struct {
            fn request(context: *anyopaque) void {
                const count: *usize = @ptrCast(@alignCast(context));
                count.* += 1;
            }
        }.request,
        .surface_changed = struct {
            fn changed(_: *anyopaque, _: Surface.Id) void {}
        }.changed,
    };

    var parent: Parent = undefined;
    parent.current = .empty;
    defer parent.current.deinit(std.testing.allocator);
    parent.pending = .empty;
    defer parent.pending.deinit(std.testing.allocator);
    try parent.current.append(std.testing.allocator, .{ .parent = {} });
    try parent.current.append(std.testing.allocator, .{ .child = child });
    try parent.pending.append(std.testing.allocator, .{ .parent = {} });
    try parent.pending.append(std.testing.allocator, .{ .child = child });

    shell.applyLiveParentState(&parent);
    try std.testing.expectEqual(@as(usize, 1), repaint_count);
    try std.testing.expectEqual(Point{ .x = 8, .y = 12 }, shell.subsurfaces.get(child).?.current_position);

    shell.applyLiveParentState(&parent);
    try std.testing.expectEqual(@as(usize, 1), repaint_count);

    const moved = parent.pending.orderedRemove(1);
    try parent.pending.insert(std.testing.allocator, 0, moved);
    shell.applyLiveParentState(&parent);
    try std.testing.expectEqual(@as(usize, 2), repaint_count);
}
