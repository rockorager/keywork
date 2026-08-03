//! Minimal native wlr-layer-shell policy for the compositor's single output.

const LayerShell = @This();

const std = @import("std");
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const Server = @import("wayring-server");
const CompositorGlobal = @import("CompositorGlobal.zig");
const OutputGlobal = @import("OutputGlobal.zig");
const SurfaceTree = @import("SurfaceTree.zig");
const render = @import("../render/types.zig");

const advertised_version: u32 = 4;
const all_anchors: u32 = 15;

allocator: std.mem.Allocator,
server: *Server,
tree: *SurfaceTree,
output: *OutputGlobal,
listener: Listener,
global_name: u32,
surfaces: std.ArrayList(*LayerSurface) = .empty,

pub const Listener = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
};

pub const Layer = enum(u2) { background, bottom, top, overlay };
pub const RootClass = enum { background, bottom, desktop, top, overlay };
pub const CommitResult = struct {
    disposition: enum { configure_only, render } = .render,
    staged: ?*StagedCommit = null,
};

pub const StagedCommit = struct {
    allocator: std.mem.Allocator,
    item: *LayerSurface,
    state: State,
    mapped: bool,

    pub fn discard(self: *StagedCommit) void {
        self.item.unreference();
        self.allocator.destroy(self);
    }
};

const State = struct {
    width: u32 = 0,
    height: u32 = 0,
    anchor: u32 = 0,
    exclusive_zone: i32 = 0,
    margin_top: i32 = 0,
    margin_right: i32 = 0,
    margin_bottom: i32 = 0,
    margin_left: i32 = 0,
    keyboard: u32 = 0,
    layer: Layer,
};

const Binding = struct {
    allocator: std.mem.Allocator,
    owner: *LayerShell,
    references: usize = 1,
    resource: wayring.ObjectHandle,

    fn reference(self: *Binding) !void {
        if (self.references == std.math.maxInt(usize)) return error.ReferenceOverflow;
        self.references += 1;
    }
    fn unreference(self: *Binding) void {
        self.references -= 1;
        if (self.references == 0) self.allocator.destroy(self);
    }
};

const LayerSurface = struct {
    allocator: std.mem.Allocator,
    binding: *Binding,
    surface: *CompositorGlobal.Surface,
    resource: wayring.ObjectHandle,
    resource_alive: bool = true,
    surface_alive: bool = true,
    references: usize = 1,
    initial_layer: Layer,
    pending: State,
    current: State,
    configures: std.ArrayList(u32) = .empty,
    initial_configure_sent: bool = false,
    configured: bool = false,
    mapped: bool = false,

    fn reference(self: *LayerSurface) !void {
        if (self.references == std.math.maxInt(usize)) return error.ReferenceOverflow;
        self.references += 1;
    }

    fn unreference(self: *LayerSurface) void {
        std.debug.assert(self.references > 0);
        self.references -= 1;
        if (self.references != 0) return;
        std.debug.assert(!self.resource_alive and !self.surface_alive);
        const owner = self.binding.owner;
        if (std.mem.indexOfScalar(*LayerSurface, owner.surfaces.items, self)) |index|
            _ = owner.surfaces.swapRemove(index);
        if (owner.tree.find(self.surface)) |node| owner.tree.detach(node);
        if (self.surface.role_context == @as(*anyopaque, @ptrCast(self))) {
            if (self.surface.role_commit_handler != null)
                self.surface.clearRoleCommitHandler(self);
            self.surface.clearRole(self);
        }
        self.surface.unreference();
        self.configures.deinit(self.allocator);
        self.binding.unreference();
        self.allocator.destroy(self);
    }

    fn releaseLifetime(self: *LayerSurface) void {
        if (!self.resource_alive and !self.surface_alive) self.unreference();
    }
};

const CapturedState = struct {
    allocator: std.mem.Allocator,
    state: State,
    fn destroy(context: *anyopaque) void {
        const self: *CapturedState = @ptrCast(@alignCast(context));
        self.allocator.destroy(self);
    }
};

pub fn init(
    self: *LayerShell,
    allocator: std.mem.Allocator,
    server: *Server,
    tree: *SurfaceTree,
    output: *OutputGlobal,
    listener: Listener,
) !void {
    self.* = .{
        .allocator = allocator,
        .server = server,
        .tree = tree,
        .output = output,
        .listener = listener,
        .global_name = undefined,
    };
    self.global_name = try server.createGlobal(&generated.zwlr_layer_shell_v1, advertised_version, .{ .context = self, .bind = bind });
}

pub fn deinit(self: *LayerShell) void {
    std.debug.assert(self.surfaces.items.len == 0);
    self.server.removeGlobal(self.global_name) catch unreachable;
    self.surfaces.deinit(self.allocator);
    self.* = undefined;
}

pub fn rootClass(self: *const LayerShell, surface: *const CompositorGlobal.Surface) RootClass {
    const layer_surface = self.forSurface(surface) orelse return .desktop;
    return switch (layer_surface.current.layer) {
        .background => .background,
        .bottom => .bottom,
        .top => .top,
        .overlay => .overlay,
    };
}

pub fn exclusiveKeyboardSurface(self: *const LayerShell) ?*CompositorGlobal.Surface {
    // Exclusive focus is only meaningful for the two policy layers above the
    // desktop.  Search overlay independently so creation order cannot let a
    // top surface outrank it.
    for ([_]Layer{ .overlay, .top }) |layer| {
        var index = self.surfaces.items.len;
        while (index > 0) {
            index -= 1;
            const item = self.surfaces.items[index];
            if (item.surface_alive and item.resource_alive and item.mapped and
                item.current.layer == layer and item.current.keyboard == 1) return item.surface;
        }
    }
    return null;
}

pub fn usableBounds(self: *const LayerShell) render.Rect {
    const size = self.output.logicalSize();
    var result: render.Rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height };
    for (self.surfaces.items) |item| {
        if (!item.mapped or item.current.exclusive_zone <= 0) continue;
        reserve(&result, item.current);
    }
    return result;
}

pub fn handleCommit(self: *LayerShell, commit: *CompositorGlobal.Commit) !?CommitResult {
    if (commit.surface.role_owner != @as(*const anyopaque, @ptrCast(self))) return null;
    const item: *LayerSurface = @ptrCast(@alignCast(commit.surface.role_context orelse return .{}));
    const role_state = commit.takeRoleState(self);
    defer if (role_state) |value| value.deinit(value.context);
    const state = if (role_state) |value| @as(*CapturedState, @ptrCast(@alignCast(value.context))).state else item.current;
    if (!validState(state)) {
        try postLayerError(item, .invalid_size, "invalid layer surface size or anchor");
        return .{};
    }
    if (!item.initial_configure_sent) {
        if (commit.attachment == .buffer) {
            try postLayerError(item, .invalid_surface_state, "buffer committed before initial configure");
            return .{};
        }
        try sendConfigure(item, state);
        return .{ .disposition = .configure_only };
    }
    if (commit.attachment == .buffer and !item.configured) {
        try postLayerError(item, .invalid_surface_state, "buffer committed before configure acknowledgement");
        return .{};
    }
    if (!std.meta.eql(state, item.current)) try sendConfigure(item, state);
    // Preflight retained-tree allocation while the transaction can still be
    // rejected without applying its buffer or role policy.
    _ = try self.tree.nodeFor(item.surface);
    const staged = try self.allocator.create(StagedCommit);
    errdefer self.allocator.destroy(staged);
    try item.reference();
    staged.* = .{
        .allocator = self.allocator,
        .item = item,
        .state = if (commit.attachment == .removed)
            .{ .layer = item.initial_layer }
        else
            state,
        .mapped = switch (commit.attachment) {
            .buffer => true,
            .removed => false,
            .unchanged => item.mapped,
        },
    };
    if (commit.attachment == .removed) {
        // Reset protocol-pending state now so commits submitted after this
        // unmap start from construction defaults even if application waits.
        item.pending = .{ .layer = item.initial_layer };
        item.configured = false;
        item.initial_configure_sent = false;
        item.configures.clearRetainingCapacity();
    }
    return .{ .staged = staged };
}

/// Applies role policy only after the compositor has atomically accepted the
/// transaction. A prepared or discarded transaction therefore cannot alter
/// stacking, reservations, focus eligibility, geometry, or mapping.
pub fn apply(self: *LayerShell, staged: *StagedCommit) !void {
    defer staged.discard();
    const item = staged.item;
    if (!item.surface_alive or !item.resource_alive) return;
    item.current = staged.state;
    item.mapped = staged.mapped;
    try self.arrange();
}

fn arrange(self: *LayerShell) !void {
    const full = self.output.logicalSize();
    var usable: render.Rect = .{ .x = 0, .y = 0, .width = full.width, .height = full.height };
    // Reserving surfaces are arranged first; every remaining layer observes
    // the final usable rectangle.
    for (self.surfaces.items) |item| if (item.mapped and item.current.exclusive_zone > 0) {
        const node = try self.tree.nodeFor(item.surface);
        const geometry = geometryFor(item.current, full);
        var update = try self.tree.captureDirect(node, .{ .x = geometry.x, .y = geometry.y }, true);
        update.apply();
        reserve(&usable, item.current);
    };
    for (self.surfaces.items) |item| if (item.mapped and item.current.exclusive_zone <= 0) {
        const bounds = if (item.current.exclusive_zone == -1) render.Rect{ .x = 0, .y = 0, .width = full.width, .height = full.height } else usable;
        const geometry = geometryIn(item.current, bounds);
        const node = try self.tree.nodeFor(item.surface);
        var update = try self.tree.captureDirect(node, .{ .x = geometry.x, .y = geometry.y }, true);
        update.apply();
    };
    // Ensure newly unmapped roots are detached from painting/hit testing.
    for (self.surfaces.items) |item| if (!item.mapped) {
        const node = self.tree.find(item.surface) orelse continue;
        var update = try self.tree.captureDirect(node, .{}, false);
        update.apply();
    };
}

fn reserve(bounds: *render.Rect, state: State) void {
    const edge = exclusiveEdge(state) orelse return;
    const margin = switch (edge) {
        1 => state.margin_top,
        2 => state.margin_bottom,
        4 => state.margin_left,
        8 => state.margin_right,
        else => 0,
    };
    const amount: u32 = @intCast(@max(0, state.exclusive_zone +| margin));
    switch (edge) {
        1 => {
            const used = @min(bounds.height, amount);
            bounds.y +|= @intCast(used);
            bounds.height -= used;
        },
        2 => bounds.height -= @min(bounds.height, amount),
        4 => {
            const used = @min(bounds.width, amount);
            bounds.x +|= @intCast(used);
            bounds.width -= used;
        },
        8 => bounds.width -= @min(bounds.width, amount),
        else => unreachable,
    }
}

pub fn deactivateFailedBuffer(self: *LayerShell, surface: *CompositorGlobal.Surface) void {
    const item = self.forSurface(surface) orelse return;
    item.mapped = false;
}

fn forSurface(self: *const LayerShell, surface: *const CompositorGlobal.Surface) ?*LayerSurface {
    if (surface.role_owner != @as(*const anyopaque, @ptrCast(self))) return null;
    const item: *LayerSurface = @ptrCast(@alignCast(surface.role_context orelse return null));
    return if (item.binding.owner == self) item else null;
}

fn bind(context: *anyopaque, client: *Server.Client, id: u32, version: u32) !void {
    const self: *LayerShell = @ptrCast(@alignCast(context));
    const binding = self.allocator.create(Binding) catch return client.postNoMemory();
    errdefer self.allocator.destroy(binding);
    binding.* = .{ .allocator = self.allocator, .owner = self, .resource = undefined };
    binding.resource = client.createResource(id, &generated.zwlr_layer_shell_v1, version, .{ .context = binding, .dispatch = dispatchManager, .destroy = destroyBinding }) catch return client.postNoMemory();
}

fn dispatchManager(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    switch (try generated.zwlr_layer_shell_v1_types.decodeRequest(&client.connection, resource, message)) {
        .destroy => {},
        .get_layer_surface => |request| {
            if (request.layer > 3) return client.postError(resource, @intFromEnum(generated.zwlr_layer_shell_v1_types.@"error".invalid_layer), "invalid layer");
            const layer: Layer = @enumFromInt(request.layer);
            if (request.output) |output_id| if (binding.owner.output.bindingHandle(client, output_id) == null) return client.postError(resource, @intFromEnum(generated.zwlr_layer_shell_v1_types.@"error".invalid_layer), "output does not belong to this client");
            const object = client.connection.object(request.surface) orelse return error.UnknownSurface;
            const surface = try CompositorGlobal.surfaceFor(client, .{ .id = request.surface, .generation = object.generation });
            if (surface.hasBuffer()) return client.postError(resource, @intFromEnum(generated.zwlr_layer_shell_v1_types.@"error".already_constructed), "wl_surface already has a pending or committed buffer");
            const item = binding.allocator.create(LayerSurface) catch return client.postNoMemory();
            errdefer binding.allocator.destroy(item);
            item.* = .{ .allocator = binding.allocator, .binding = binding, .surface = surface, .resource = undefined, .initial_layer = layer, .pending = .{ .layer = layer }, .current = .{ .layer = layer } };
            surface.reference() catch return client.postNoMemory();
            errdefer surface.unreference();
            surface.setRole(binding.owner, item, surfaceDestroyed) catch return client.postError(resource, @intFromEnum(generated.zwlr_layer_shell_v1_types.@"error".role), "wl_surface already has a role");
            errdefer surface.clearRole(item);
            surface.setRoleCommitHandler(.{ .context = item, .capture = captureCommit });
            errdefer surface.clearRoleCommitHandler(item);
            binding.reference() catch return client.postNoMemory();
            errdefer binding.unreference();
            try binding.owner.surfaces.append(binding.allocator, item);
            errdefer _ = binding.owner.surfaces.pop();
            const version = @min(try client.resourceVersion(resource, &generated.zwlr_layer_shell_v1), generated.zwlr_layer_surface_v1.version);
            item.resource = client.createResource(request.id, &generated.zwlr_layer_surface_v1, version, .{ .context = item, .dispatch = dispatchSurface, .destroy = destroyLayerSurface }) catch return client.postNoMemory();
        },
    }
}

fn dispatchSurface(context: *anyopaque, client: *Server.Client, resource: wayring.ObjectHandle, message: *wayring.Message) !void {
    const item: *LayerSurface = @ptrCast(@alignCast(context));
    switch (try generated.zwlr_layer_surface_v1_types.decodeRequest(&client.connection, resource, message)) {
        .set_size => |r| {
            item.pending.width = r.width;
            item.pending.height = r.height;
        },
        .set_anchor => |r| if (r.anchor & ~all_anchors != 0) return postLayerError(item, .invalid_anchor, "invalid anchor") else {
            item.pending.anchor = r.anchor;
        },
        .set_exclusive_zone => |r| item.pending.exclusive_zone = r.zone,
        .set_margin => |r| {
            item.pending.margin_top = r.top;
            item.pending.margin_right = r.right;
            item.pending.margin_bottom = r.bottom;
            item.pending.margin_left = r.left;
        },
        .set_keyboard_interactivity => |r| {
            const version = try client.resourceVersion(resource, &generated.zwlr_layer_surface_v1);
            if (r.keyboard_interactivity > 1 and (r.keyboard_interactivity != 2 or version < 4))
                return postLayerError(item, .invalid_keyboard_interactivity, "invalid keyboard interactivity");
            item.pending.keyboard = r.keyboard_interactivity;
        },
        .get_popup => return postLayerError(item, .invalid_surface_state, "layer-parented popups are not supported"),
        .ack_configure => |r| {
            const index = std.mem.indexOfScalar(u32, item.configures.items, r.serial) orelse return postLayerError(item, .invalid_surface_state, "unknown configure serial");
            item.configures.replaceRangeAssumeCapacity(0, index + 1, &.{});
            item.configured = true;
        },
        .destroy => {},
        .set_layer => |r| {
            if (r.layer > 3) return postLayerError(item, .invalid_surface_state, "invalid layer");
            item.pending.layer = @enumFromInt(r.layer);
        },
        .set_exclusive_edge => unreachable,
    }
}

fn captureCommit(context: *anyopaque) !?CompositorGlobal.RoleCommitState {
    const item: *LayerSurface = @ptrCast(@alignCast(context));
    const captured = try item.allocator.create(CapturedState);
    captured.* = .{ .allocator = item.allocator, .state = item.pending };
    return .{ .owner = item.binding.owner, .context = captured, .deinit = CapturedState.destroy };
}

fn sendConfigure(item: *LayerSurface, state: State) !void {
    const geometry = geometryFor(state, item.binding.owner.output.logicalSize());
    const serial = item.surface.owner.server.nextSerial();
    try item.configures.append(item.allocator, serial);
    errdefer _ = item.configures.pop();
    try generated.zwlr_layer_surface_v1_types.events.configure(&item.surface.client.connection, item.resource, serial, geometry.width, geometry.height);
    item.initial_configure_sent = true;
}

fn validState(state: State) bool {
    if (state.width == 0 and (state.anchor & (4 | 8)) != (4 | 8)) return false;
    if (state.height == 0 and (state.anchor & (1 | 2)) != (1 | 2)) return false;
    return true;
}

fn geometryFor(state: State, output: render.Size) render.Rect {
    return geometryIn(state, .{ .x = 0, .y = 0, .width = output.width, .height = output.height });
}

fn geometryIn(state: State, bounds: render.Rect) render.Rect {
    const output: render.Size = .{ .width = bounds.width, .height = bounds.height };
    var width = if (state.width == 0) output.width else @min(output.width, state.width);
    var height = if (state.height == 0) output.height else @min(output.height, state.height);
    if (state.width == 0) width -|= @intCast(@max(0, state.margin_left) +| @max(0, state.margin_right));
    if (state.height == 0) height -|= @intCast(@max(0, state.margin_top) +| @max(0, state.margin_bottom));
    var x: i32 = @divTrunc(@as(i32, @intCast(output.width - width)), 2);
    var y: i32 = @divTrunc(@as(i32, @intCast(output.height - height)), 2);
    if (state.anchor & 4 != 0) x = state.margin_left else if (state.anchor & 8 != 0) x = @as(i32, @intCast(output.width - width)) -| state.margin_right;
    if (state.anchor & 1 != 0) y = state.margin_top else if (state.anchor & 2 != 0) y = @as(i32, @intCast(output.height - height)) -| state.margin_bottom;
    return .{ .x = x +| bounds.x, .y = y +| bounds.y, .width = width, .height = height };
}

fn exclusiveEdge(state: State) ?u32 {
    const horizontal = state.anchor & (4 | 8);
    const vertical = state.anchor & (1 | 2);
    if (vertical == 1 and (horizontal == 0 or horizontal == 12)) return 1;
    if (vertical == 2 and (horizontal == 0 or horizontal == 12)) return 2;
    if (horizontal == 4 and (vertical == 0 or vertical == 3)) return 4;
    if (horizontal == 8 and (vertical == 0 or vertical == 3)) return 8;
    return null;
}

fn postLayerError(item: *LayerSurface, code: generated.zwlr_layer_surface_v1_types.@"error", message: []const u8) !void {
    return item.surface.client.postError(item.resource, @intFromEnum(code), message);
}

fn surfaceDestroyed(context: *anyopaque) void {
    const item: *LayerSurface = @ptrCast(@alignCast(context));
    item.surface_alive = false;
    item.mapped = false;
    if (item.surface.role_commit_handler != null)
        item.surface.clearRoleCommitHandler(item);
    item.binding.owner.arrange() catch {};
    item.binding.owner.listener.changed(item.binding.owner.listener.context);
    item.releaseLifetime();
}
fn destroyLayerSurface(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const item: *LayerSurface = @ptrCast(@alignCast(context));
    item.resource_alive = false;
    item.mapped = false;
    if (item.surface.role_commit_handler != null)
        item.surface.clearRoleCommitHandler(item);
    item.binding.owner.arrange() catch {};
    item.binding.owner.listener.changed(item.binding.owner.listener.context);
    item.releaseLifetime();
}
fn destroyBinding(context: *anyopaque, _: *Server.Client, _: wayring.ObjectHandle) void {
    const binding: *Binding = @ptrCast(@alignCast(context));
    binding.unreference();
}

test "geometry covers shell placements and exclusive usable area edge" {
    const output: render.Size = .{ .width = 1280, .height = 720 };
    try std.testing.expectEqual(render.Rect{ .x = 0, .y = 8, .width = 1280, .height = 32 }, geometryFor(.{ .width = 0, .height = 32, .anchor = 1 | 4 | 8, .margin_top = 8, .layer = .top }, output));
    try std.testing.expectEqual(render.Rect{ .x = 440, .y = 260, .width = 400, .height = 200 }, geometryFor(.{ .width = 400, .height = 200, .layer = .overlay }, output));
    try std.testing.expectEqual(render.Rect{ .x = 536, .y = 576, .width = 208, .height = 48 }, geometryFor(.{ .width = 208, .height = 48, .anchor = 2, .margin_bottom = 96, .layer = .overlay }, output));
    try std.testing.expectEqual(render.Rect{ .x = 880, .y = 16, .width = 380, .height = 200 }, geometryFor(.{ .width = 380, .height = 200, .anchor = 1 | 8, .margin_top = 16, .margin_right = 20, .layer = .overlay }, output));
    try std.testing.expectEqual(@as(?u32, 1), exclusiveEdge(.{ .anchor = 1 | 4 | 8, .layer = .top }));

    var usable: render.Rect = .{ .x = 0, .y = 0, .width = 1280, .height = 720 };
    reserve(&usable, .{ .anchor = 1 | 4 | 8, .exclusive_zone = 40, .margin_top = 8, .layer = .top });
    try std.testing.expectEqual(render.Rect{ .x = 0, .y = 48, .width = 1280, .height = 672 }, usable);
    try std.testing.expectEqual(render.Rect{ .x = 440, .y = 284, .width = 400, .height = 200 }, geometryIn(.{ .width = 400, .height = 200, .layer = .overlay }, usable));
}

test "native layer surface configures transactionally and outlives its manager" {
    const core = @import("wayring-core");
    const Changed = struct {
        fn changed(_: *anyopaque) void {}
    };

    var server = Server.init(std.testing.allocator);
    defer server.deinit();
    var compositor: CompositorGlobal = undefined;
    try compositor.init(std.testing.allocator, &server);
    defer compositor.deinit();
    var output: OutputGlobal = undefined;
    try output.init(std.testing.allocator, &server, .{
        .mode_size = .{ .width = 1280, .height = 720 },
        .logical_size = .{ .width = 1280, .height = 720 },
        .physical_size = .{ .width = 300, .height = 170 },
        .refresh_millihertz = 60_000,
        .scale = 1,
        .name = "TEST-1",
        .description = "Test output",
        .model = "test",
    });
    defer output.deinit();
    var tree = SurfaceTree.init(std.testing.allocator);
    defer tree.deinit();
    var shell: LayerShell = undefined;
    try shell.init(
        std.testing.allocator,
        &server,
        &tree,
        &output,
        .{ .context = &shell, .changed = Changed.changed },
    );
    defer shell.deinit();
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
    try transferToLayerServer(&peer, client);
    try transferFromLayerServer(&peer, client);
    var compositor_name: u32 = 0;
    var shell_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.zwlr_layer_shell_v1.name))
            shell_name = global.name;
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
    const shell_resource: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            shell_name,
            generated.zwlr_layer_shell_v1.name,
            advertised_version,
            4,
            &generated.zwlr_layer_shell_v1,
        ),
    };
    try transferToLayerServer(&peer, client);
    const surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor_resource,
    );
    const layer_surface = try generated.zwlr_layer_shell_v1_types.requests.get_layer_surface(
        &peer,
        shell_resource,
        surface,
        null,
        @intFromEnum(generated.zwlr_layer_shell_v1_types.layer.top),
        "keywork-test",
    );
    try generated.zwlr_layer_surface_v1_types.requests.set_size(&peer, layer_surface, 0, 40);
    try generated.zwlr_layer_surface_v1_types.requests.set_anchor(
        &peer,
        layer_surface,
        generated.zwlr_layer_surface_v1_types.anchor.top |
            generated.zwlr_layer_surface_v1_types.anchor.left |
            generated.zwlr_layer_surface_v1_types.anchor.right,
    );
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToLayerServer(&peer, client);
    var initial_transaction = compositor.popTransaction() orelse return error.MissingCommit;
    defer initial_transaction.deinit();
    try std.testing.expectEqual(
        .configure_only,
        (try shell.handleCommit(&initial_transaction.entries[0])).?.disposition,
    );
    try transferFromLayerServer(&peer, client);
    var configure_serial: ?u32 = null;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != layer_surface.id) continue;
        const configure = (try generated.zwlr_layer_surface_v1_types.decodeEvent(
            &peer,
            layer_surface,
            &message,
        )).configure;
        try std.testing.expectEqual(@as(u32, 1280), configure.width);
        try std.testing.expectEqual(@as(u32, 40), configure.height);
        configure_serial = configure.serial;
    }
    try generated.zwlr_layer_surface_v1_types.requests.ack_configure(
        &peer,
        layer_surface,
        configure_serial orelse return error.MissingConfigure,
    );
    try generated.zwlr_layer_surface_v1_types.requests.set_size(&peer, layer_surface, 0, 48);
    try generated.wl_surface_types.requests.commit(&peer, surface);
    try transferToLayerServer(&peer, client);
    var resize_transaction = compositor.popTransaction() orelse return error.MissingResizeCommit;
    defer resize_transaction.deinit();
    const result = (try shell.handleCommit(&resize_transaction.entries[0])).?;
    const staged = result.staged orelse return error.MissingStagedLayerCommit;
    try std.testing.expectEqual(@as(u32, 0), shell.surfaces.items[0].current.width);
    try std.testing.expectEqual(@as(u32, 0), shell.surfaces.items[0].current.height);
    try shell.apply(staged);
    try std.testing.expectEqual(@as(u32, 48), shell.surfaces.items[0].current.height);

    try generated.zwlr_layer_shell_v1_types.requests.destroy(&peer, shell_resource);
    try transferToLayerServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 1), shell.surfaces.items.len);
    try generated.zwlr_layer_surface_v1_types.requests.destroy(&peer, layer_surface);
    try generated.wl_surface_types.requests.destroy(&peer, surface);
    try transferToLayerServer(&peer, client);
    try std.testing.expectEqual(@as(usize, 0), shell.surfaces.items.len);
}

fn transferToLayerServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (connection.nextBatch()) |batch| {
        try client.receive(batch.bytes, batch.fds);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
}

fn transferFromLayerServer(connection: *wayring.Connection, client: *Server.Client) !void {
    while (client.connection.nextBatch()) |batch| {
        try connection.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}
