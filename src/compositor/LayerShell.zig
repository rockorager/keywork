//! Protocol-resource-free semantic state for layer surfaces.
//!
//! Frontends translate protocol enums and serials at this boundary. This owner
//! deliberately has no placement, scene, focus, or usable-area policy.

const LayerShell = @This();

const std = @import("std");
const slot_map = @import("slot_map.zig");
const ClientRegistry = @import("ClientRegistry.zig");
const SurfaceRegistry = @import("SurfaceRegistry.zig");
const OutputLayout = @import("output_layout.zig");

const Store = slot_map.SlotMap(Surface, enum { layer_surface });
pub const LayerSurfaceId = Store.Id;

pub const Layer = enum(u32) { background, bottom, top, overlay, _ };
pub const Anchor = packed struct(u32) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
    _reserved: u28 = 0,
};
pub const Margins = struct { top: i32 = 0, right: i32 = 0, bottom: i32 = 0, left: i32 = 0 };
pub const KeyboardInteractivity = enum(u32) { none, exclusive, on_demand, _ };
pub const State = struct {
    width: u32 = 0,
    height: u32 = 0,
    anchor: Anchor = .{},
    exclusive_zone: i32 = 0,
    margins: Margins = .{},
    keyboard_interactivity: KeyboardInteractivity = .none,
    layer: Layer,
    exclusive_edge: Anchor = .{},
};
pub const ConfigureToken = struct { surface: LayerSurfaceId, sequence: u64 };
pub const Snapshot = struct {
    client: ClientRegistry.Id,
    surface: SurfaceRegistry.Id,
    output: OutputLayout.Id,
    namespace: []const u8,
    pending: State,
    current: State,
    awaiting_initial_commit: bool,
    configured: bool,
    mapped: bool,
};
pub const Endpoint = struct {
    context: *anyopaque,
    configure: *const fn (*anyopaque, u32, u32, ConfigureToken) error{OutOfMemory}!void,
    close: *const fn (*anyopaque) void,
};
pub const Observer = struct {
    context: *anyopaque,
    applying: *const fn (*anyopaque, LayerSurfaceId, State) error{OutOfMemory}!void,
    committed: *const fn (*anyopaque, LayerSurfaceId, Snapshot) void,
    unmapped: *const fn (*anyopaque, LayerSurfaceId) void,
    destroyed: *const fn (*anyopaque, LayerSurfaceId) void,
};

pub const ValidationError = error{
    InvalidAnchor,
    InvalidKeyboardInteractivity,
    InvalidLayer,
    InvalidExclusiveEdge,
    InvalidSize,
};
pub const CreateError = error{ OutOfMemory, InvalidClient, InvalidSurface, InvalidOutput, InvalidNamespace, InvalidLayer };
pub const AccessError = error{InvalidLayerSurface};
pub const AckError = error{ InvalidLayerSurface, ForeignConfigure, StaleConfigure };
pub const CommitValidationError = ValidationError || error{ InvalidLayerSurface, UnconfiguredBuffer };
pub const CommitError = error{ InvalidLayerSurface, OutOfMemory };

const Surface = struct {
    client: ClientRegistry.Id,
    surface: SurfaceRegistry.Id,
    output: OutputLayout.Id,
    namespace: []u8,
    initial_layer: Layer,
    pending: State,
    current: State,
    endpoint: Endpoint,
    configure_tokens: std.ArrayList(ConfigureToken) = .empty,
    next_sequence: u64 = 1,
    awaiting_initial_commit: bool = true,
    configured: bool = false,
    acked: bool = false,
    mapped: bool = false,

    fn deinit(self: *Surface, allocator: std.mem.Allocator) void {
        allocator.free(self.namespace);
        self.configure_tokens.deinit(allocator);
    }
};

allocator: std.mem.Allocator,
clients: *const ClientRegistry,
surface_registry: *const SurfaceRegistry,
output_context: *anyopaque,
output_valid: *const fn (*anyopaque, OutputLayout.Id) bool,
surfaces: Store = .{},
observer: ?Observer = null,

pub fn init(allocator: std.mem.Allocator, clients: *const ClientRegistry, surface_registry: *const SurfaceRegistry, output_context: *anyopaque, output_valid: *const fn (*anyopaque, OutputLayout.Id) bool) LayerShell {
    return .{ .allocator = allocator, .clients = clients, .surface_registry = surface_registry, .output_context = output_context, .output_valid = output_valid };
}

pub fn deinit(self: *LayerShell) void {
    std.debug.assert(self.surfaces.len() == 0);
    self.surfaces.deinit(self.allocator);
    self.* = undefined;
}

pub fn createSurface(self: *LayerShell, client: ClientRegistry.Id, surface: SurfaceRegistry.Id, output: OutputLayout.Id, namespace: []const u8, layer: Layer, endpoint: Endpoint) CreateError!LayerSurfaceId {
    if (!self.clients.contains(client)) return error.InvalidClient;
    if (!self.surface_registry.contains(surface)) return error.InvalidSurface;
    if (!self.output_valid(self.output_context, output)) return error.InvalidOutput;
    if (!std.unicode.utf8ValidateSlice(namespace)) return error.InvalidNamespace;
    validateLayer(layer) catch return error.InvalidLayer;
    const owned_namespace = try self.allocator.dupe(u8, namespace);
    errdefer self.allocator.free(owned_namespace);
    const state: State = .{ .layer = layer };
    return self.surfaces.insert(self.allocator, .{
        .client = client,
        .surface = surface,
        .output = output,
        .namespace = owned_namespace,
        .initial_layer = layer,
        .pending = state,
        .current = state,
        .endpoint = endpoint,
    });
}

pub fn destroySurface(self: *LayerShell, id: LayerSurfaceId) void {
    var state = self.surfaces.remove(id) orelse return;
    if (self.observer) |observer| observer.destroyed(observer.context, id);
    state.deinit(self.allocator);
}

pub fn snapshot(self: *const LayerShell, id: LayerSurfaceId) ?Snapshot {
    const state = self.surfaces.getConst(id) orelse return null;
    return snapshotOf(state);
}

pub fn surfaceFor(self: *LayerShell, surface: SurfaceRegistry.Id) ?LayerSurfaceId {
    var iterator = self.surfaces.iterator();
    while (iterator.next()) |entry| {
        if (std.meta.eql(entry.value.surface, surface)) return entry.id;
    }
    return null;
}

fn snapshotOf(state: *const Surface) Snapshot {
    return .{ .client = state.client, .surface = state.surface, .output = state.output, .namespace = state.namespace, .pending = state.pending, .current = state.current, .awaiting_initial_commit = state.awaiting_initial_commit, .configured = state.configured, .mapped = state.mapped };
}

pub fn setSize(self: *LayerShell, id: LayerSurfaceId, width: u32, height: u32) AccessError!void {
    const s = self.surfaces.get(id) orelse return error.InvalidLayerSurface;
    s.pending.width = width;
    s.pending.height = height;
}
pub fn setAnchorRaw(self: *LayerShell, id: LayerSurfaceId, value: u32) AccessError!void {
    const s = self.surfaces.get(id) orelse return error.InvalidLayerSurface;
    s.pending.anchor = @bitCast(value);
}
pub fn setExclusiveZone(self: *LayerShell, id: LayerSurfaceId, value: i32) AccessError!void {
    const s = self.surfaces.get(id) orelse return error.InvalidLayerSurface;
    s.pending.exclusive_zone = value;
}
pub fn setMargins(self: *LayerShell, id: LayerSurfaceId, value: Margins) AccessError!void {
    const s = self.surfaces.get(id) orelse return error.InvalidLayerSurface;
    s.pending.margins = value;
}
pub fn setKeyboardRaw(self: *LayerShell, id: LayerSurfaceId, value: u32) AccessError!void {
    const s = self.surfaces.get(id) orelse return error.InvalidLayerSurface;
    s.pending.keyboard_interactivity = @enumFromInt(value);
}
pub fn setLayerRaw(self: *LayerShell, id: LayerSurfaceId, value: u32) AccessError!void {
    const s = self.surfaces.get(id) orelse return error.InvalidLayerSurface;
    s.pending.layer = @enumFromInt(value);
}
pub fn setExclusiveEdgeRaw(self: *LayerShell, id: LayerSurfaceId, value: u32) AccessError!void {
    const s = self.surfaces.get(id) orelse return error.InvalidLayerSurface;
    s.pending.exclusive_edge = @bitCast(value);
}

/// Error order is part of the adapter contract and matches the mature frontend.
pub fn validate(state: State) ValidationError!void {
    const anchors: u32 = @bitCast(state.anchor);
    if (anchors > 15) return error.InvalidAnchor;
    validateKeyboard(state.keyboard_interactivity) catch return error.InvalidKeyboardInteractivity;
    validateLayer(state.layer) catch return error.InvalidLayer;
    if (!validExclusiveEdge(state)) return error.InvalidExclusiveEdge;
    if ((state.width == 0 and !(state.anchor.left and state.anchor.right)) or
        (state.height == 0 and !(state.anchor.top and state.anchor.bottom))) return error.InvalidSize;
}

fn validateLayer(value: Layer) error{InvalidLayer}!void {
    switch (value) {
        .background, .bottom, .top, .overlay => {},
        _ => return error.InvalidLayer,
    }
}
fn validateKeyboard(value: KeyboardInteractivity) error{InvalidKeyboardInteractivity}!void {
    switch (value) {
        .none, .exclusive, .on_demand => {},
        _ => return error.InvalidKeyboardInteractivity,
    }
}
fn validExclusiveEdge(state: State) bool {
    const edge: u32 = @bitCast(state.exclusive_edge);
    const anchor: u32 = @bitCast(state.anchor);
    return edge == 0 or (@popCount(edge) == 1 and (edge & anchor) != 0);
}

pub fn sendConfigure(self: *LayerShell, id: LayerSurfaceId, width: u32, height: u32) (AccessError || error{ OutOfMemory, ConfigureSequenceExhausted })!ConfigureToken {
    const state = self.surfaces.get(id) orelse return error.InvalidLayerSurface;
    if (state.next_sequence == 0) return error.ConfigureSequenceExhausted;
    const token: ConfigureToken = .{ .surface = id, .sequence = state.next_sequence };
    try state.configure_tokens.append(self.allocator, token);
    errdefer _ = state.configure_tokens.pop();
    try state.endpoint.configure(state.endpoint.context, width, height, token);
    state.next_sequence +%= 1;
    state.configured = true;
    return token;
}

pub fn ackConfigure(self: *LayerShell, id: LayerSurfaceId, token: ConfigureToken) AckError!void {
    const state = self.surfaces.get(id) orelse return error.InvalidLayerSurface;
    if (!std.meta.eql(token.surface, id)) return error.ForeignConfigure;
    for (state.configure_tokens.items, 0..) |candidate, index| {
        if (!std.meta.eql(candidate, token)) continue;
        var count = index + 1;
        while (count > 0) : (count -= 1) _ = state.configure_tokens.orderedRemove(0);
        state.acked = true;
        return;
    }
    return error.StaleConfigure;
}

pub fn validateCommit(self: *const LayerShell, id: LayerSurfaceId, has_buffer: bool) CommitValidationError!void {
    const state = self.surfaces.getConst(id) orelse return error.InvalidLayerSurface;
    try validate(state.pending);
    if (has_buffer and !state.acked) return error.UnconfiguredBuffer;
}

/// Applies a commit after the canonical surface owner reports that it took
/// effect. The observer prepares canonical policy state before this owner
/// advances current state, so an allocation failure leaves the transaction
/// retryable.
pub fn applyCommit(self: *LayerShell, id: LayerSurfaceId, has_buffer: bool) CommitError!void {
    const state = self.surfaces.get(id) orelse return error.InvalidLayerSurface;
    if (!has_buffer and state.mapped) {
        const reset: State = .{ .layer = state.initial_layer };
        state.mapped = false;
        state.configured = false;
        state.acked = false;
        state.awaiting_initial_commit = true;
        state.configure_tokens.clearRetainingCapacity();
        state.pending = reset;
        state.current = reset;
        if (self.observer) |observer| observer.unmapped(observer.context, id);
    } else {
        if (self.observer) |observer| try observer.applying(observer.context, id, state.pending);
        state.current = state.pending;
        state.awaiting_initial_commit = false;
        if (has_buffer) state.mapped = true;
    }
    if (self.observer) |observer| observer.committed(observer.context, id, snapshotOf(state));
}

pub fn close(self: *LayerShell, id: LayerSurfaceId) void {
    const state = self.surfaces.get(id) orelse return;
    state.endpoint.close(state.endpoint.context);
}

pub fn clientDisconnected(self: *LayerShell, client: ClientRegistry.Id) void {
    self.removeMatching(.client, client);
}
pub fn surfaceDestroyed(self: *LayerShell, surface: SurfaceRegistry.Id) void {
    self.removeMatching(.surface, surface);
}
pub fn outputRemoved(self: *LayerShell, output: OutputLayout.Id) void {
    while (true) {
        var found: ?LayerSurfaceId = null;
        var it = self.surfaces.iterator();
        while (it.next()) |entry| if (std.meta.eql(entry.value.output, output)) {
            found = entry.id;
            break;
        };
        const id = found orelse return;
        const endpoint = self.surfaces.get(id).?.endpoint;
        endpoint.close(endpoint.context);
        self.destroySurface(id);
    }
}

fn removeMatching(self: *LayerShell, comptime field: enum { client, surface, output }, value: anytype) void {
    while (true) {
        var found: ?LayerSurfaceId = null;
        var it = self.surfaces.iterator();
        while (it.next()) |entry| if (std.meta.eql(@field(entry.value, @tagName(field)), value)) {
            found = entry.id;
            break;
        };
        self.destroySurface(found orelse return);
    }
}

pub fn setObserver(self: *LayerShell, observer: Observer) void {
    self.observer = observer;
}
pub fn clearObserver(self: *LayerShell, context: *anyopaque) void {
    if (self.observer) |observer| {
        if (observer.context == context) self.observer = null;
    }
}

test "validation keeps mature error precedence" {
    var state: State = .{ .layer = .top };
    try std.testing.expectError(error.InvalidSize, validate(state));
    state.anchor = @bitCast(@as(u32, 16));
    state.keyboard_interactivity = @enumFromInt(99);
    state.layer = @enumFromInt(99);
    try std.testing.expectError(error.InvalidAnchor, validate(state));
    state.anchor = .{ .top = true, .left = true, .right = true };
    try std.testing.expectError(error.InvalidKeyboardInteractivity, validate(state));
    state.keyboard_interactivity = .none;
    try std.testing.expectError(error.InvalidLayer, validate(state));
    state.layer = .top;
    state.anchor = .{ .top = true, .left = true, .right = true };
    state.height = 1;
    state.exclusive_edge = .{ .bottom = true };
    try std.testing.expectError(error.InvalidExclusiveEdge, validate(state));
}

const TestOutput = struct {
    id: OutputLayout.Id = .{ .index = 7, .generation = 2 },

    fn valid(context: *anyopaque, id: OutputLayout.Id) bool {
        const self: *TestOutput = @ptrCast(@alignCast(context));
        return std.meta.eql(self.id, id);
    }
};

const TestEndpoint = struct {
    tokens: [4]ConfigureToken = undefined,
    token_count: usize = 0,
    close_count: usize = 0,
    fail_configure: bool = false,
    chronology: ?*std.ArrayList(u8) = null,

    fn endpoint(self: *TestEndpoint) Endpoint {
        return .{
            .context = self,
            .configure = TestEndpoint.configure,
            .close = TestEndpoint.close,
        };
    }

    fn configure(context: *anyopaque, _: u32, _: u32, token: ConfigureToken) error{OutOfMemory}!void {
        const self: *TestEndpoint = @ptrCast(@alignCast(context));
        if (self.fail_configure) return error.OutOfMemory;
        self.tokens[self.token_count] = token;
        self.token_count += 1;
    }

    fn close(context: *anyopaque) void {
        const self: *TestEndpoint = @ptrCast(@alignCast(context));
        self.close_count += 1;
        if (self.chronology) |chronology| chronology.append(std.testing.allocator, 'c') catch unreachable;
    }
};

const TestObserver = struct {
    apply_count: usize = 0,
    commit_count: usize = 0,
    unmap_count: usize = 0,
    destroy_count: usize = 0,
    fail_apply: bool = false,
    chronology: ?*std.ArrayList(u8) = null,

    fn observer(self: *TestObserver) Observer {
        return .{
            .context = self,
            .applying = applying,
            .committed = committed,
            .unmapped = unmapped,
            .destroyed = destroyed,
        };
    }

    fn applying(context: *anyopaque, _: LayerSurfaceId, _: State) error{OutOfMemory}!void {
        const self: *TestObserver = @ptrCast(@alignCast(context));
        if (self.fail_apply) return error.OutOfMemory;
        self.apply_count += 1;
    }

    fn committed(context: *anyopaque, _: LayerSurfaceId, _: Snapshot) void {
        const self: *TestObserver = @ptrCast(@alignCast(context));
        self.commit_count += 1;
    }

    fn unmapped(context: *anyopaque, _: LayerSurfaceId) void {
        const self: *TestObserver = @ptrCast(@alignCast(context));
        self.unmap_count += 1;
    }

    fn destroyed(context: *anyopaque, _: LayerSurfaceId) void {
        const self: *TestObserver = @ptrCast(@alignCast(context));
        self.destroy_count += 1;
        if (self.chronology) |chronology| chronology.append(std.testing.allocator, 'd') catch unreachable;
    }
};

const TestProvider = struct {
    fn renderState(_: *anyopaque) ?SurfaceRegistry.RenderState {
        return null;
    }
};

test "transactions own namespace configure acknowledgements and remap state" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    const client = try clients.register(.mature_display);
    defer clients.unregister(client);
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var provider: TestProvider = .{};
    const surface = try surfaces.add(.{ .context = &provider, .render_state = TestProvider.renderState });
    defer surfaces.remove(surface);
    var output: TestOutput = .{};
    var shell = LayerShell.init(std.testing.allocator, &clients, &surfaces, &output, TestOutput.valid);
    defer shell.deinit();
    var endpoint: TestEndpoint = .{};
    var observer: TestObserver = .{};
    shell.setObserver(observer.observer());
    defer shell.clearObserver(&observer);

    var namespace = [_]u8{ 'p', 'a', 'n', 'e', 'l' };
    const id = try shell.createSurface(client, surface, output.id, &namespace, .top, endpoint.endpoint());
    namespace[0] = 'x';
    try std.testing.expectEqualStrings("panel", shell.snapshot(id).?.namespace);
    try shell.setSize(id, 40, 20);
    try shell.validateCommit(id, false);
    try shell.applyCommit(id, false);
    try std.testing.expect(!shell.snapshot(id).?.awaiting_initial_commit);
    try std.testing.expectError(error.UnconfiguredBuffer, shell.validateCommit(id, true));

    const first = try shell.sendConfigure(id, 40, 20);
    const second = try shell.sendConfigure(id, 80, 20);
    try shell.ackConfigure(id, second);
    try std.testing.expectError(error.StaleConfigure, shell.ackConfigure(id, first));
    try shell.validateCommit(id, true);
    try shell.applyCommit(id, true);
    try std.testing.expect(shell.snapshot(id).?.mapped);

    try shell.setLayerRaw(id, @intFromEnum(Layer.overlay));
    try shell.applyCommit(id, true);
    try std.testing.expectEqual(Layer.overlay, shell.snapshot(id).?.current.layer);
    observer.fail_apply = true;
    try std.testing.expectError(error.OutOfMemory, shell.applyCommit(id, true));
    try std.testing.expectEqual(Layer.overlay, shell.snapshot(id).?.current.layer);
    try shell.applyCommit(id, false);
    const reset = shell.snapshot(id).?;
    try std.testing.expect(!reset.mapped);
    try std.testing.expect(reset.awaiting_initial_commit);
    try std.testing.expectEqual(Layer.top, reset.current.layer);
    try std.testing.expectEqual(@as(usize, 1), observer.unmap_count);
    observer.fail_apply = false;
    try shell.setSize(id, 40, 20);
    try std.testing.expectError(error.UnconfiguredBuffer, shell.validateCommit(id, true));

    shell.destroySurface(id);
    const replacement = try shell.createSurface(client, surface, output.id, "replacement", .bottom, endpoint.endpoint());
    try std.testing.expectEqual(id.index, replacement.index);
    try std.testing.expect(id.generation != replacement.generation);
    try std.testing.expectError(error.InvalidLayerSurface, shell.setSize(id, 1, 1));
    try std.testing.expectError(error.ForeignConfigure, shell.ackConfigure(replacement, second));
    shell.destroySurface(replacement);
}

test "configure publication rollback and sequence exhaustion are explicit" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    const client = try clients.register(.wayring_server);
    defer clients.unregister(client);
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var provider: TestProvider = .{};
    const surface = try surfaces.add(.{ .context = &provider, .render_state = TestProvider.renderState });
    defer surfaces.remove(surface);
    var output: TestOutput = .{};
    var shell = LayerShell.init(std.testing.allocator, &clients, &surfaces, &output, TestOutput.valid);
    defer shell.deinit();
    var endpoint: TestEndpoint = .{ .fail_configure = true };
    const id = try shell.createSurface(client, surface, output.id, "osd", .overlay, endpoint.endpoint());
    defer shell.destroySurface(id);
    try std.testing.expectError(error.OutOfMemory, shell.sendConfigure(id, 1, 1));
    try std.testing.expect(!shell.snapshot(id).?.configured);
    endpoint.fail_configure = false;
    try std.testing.expectEqual(@as(u64, 1), (try shell.sendConfigure(id, 1, 1)).sequence);
    shell.surfaces.get(id).?.next_sequence = std.math.maxInt(u64);
    try std.testing.expectEqual(std.math.maxInt(u64), (try shell.sendConfigure(id, 2, 2)).sequence);
    try std.testing.expectError(error.ConfigureSequenceExhausted, shell.sendConfigure(id, 3, 3));
}

test "creation validation and namespace allocation roll back" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    const client = try clients.register(.mature_display);
    defer clients.unregister(client);
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var provider: TestProvider = .{};
    const surface = try surfaces.add(.{ .context = &provider, .render_state = TestProvider.renderState });
    defer surfaces.remove(surface);
    var output: TestOutput = .{};
    var endpoint: TestEndpoint = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var shell = LayerShell.init(failing.allocator(), &clients, &surfaces, &output, TestOutput.valid);
    try std.testing.expectError(error.OutOfMemory, shell.createSurface(client, surface, output.id, "panel", .top, endpoint.endpoint()));
    shell.deinit();

    var valid_shell = LayerShell.init(std.testing.allocator, &clients, &surfaces, &output, TestOutput.valid);
    defer valid_shell.deinit();
    try std.testing.expectError(error.InvalidClient, valid_shell.createSurface(.{ .index = 99, .generation = 1 }, surface, output.id, "panel", .top, endpoint.endpoint()));
    try std.testing.expectError(error.InvalidSurface, valid_shell.createSurface(client, .{ .index = 99, .generation = 1 }, output.id, "panel", .top, endpoint.endpoint()));
    try std.testing.expectError(error.InvalidNamespace, valid_shell.createSurface(client, surface, output.id, "\xff", .top, endpoint.endpoint()));
    try std.testing.expectError(error.InvalidOutput, valid_shell.createSurface(client, surface, .{ .index = 8, .generation = 1 }, "panel", .top, endpoint.endpoint()));
    try std.testing.expectError(error.InvalidLayer, valid_shell.createSurface(client, surface, output.id, "panel", @enumFromInt(9), endpoint.endpoint()));
}

test "client and canonical surface teardown remove only matching roles" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    const first_client = try clients.register(.mature_display);
    defer clients.unregister(first_client);
    const second_client = try clients.register(.wayring_server);
    defer clients.unregister(second_client);
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var first_provider: TestProvider = .{};
    var second_provider: TestProvider = .{};
    const first_surface = try surfaces.add(.{ .context = &first_provider, .render_state = TestProvider.renderState });
    defer surfaces.remove(first_surface);
    const second_surface = try surfaces.add(.{ .context = &second_provider, .render_state = TestProvider.renderState });
    defer surfaces.remove(second_surface);
    var output: TestOutput = .{};
    var shell = LayerShell.init(std.testing.allocator, &clients, &surfaces, &output, TestOutput.valid);
    defer shell.deinit();
    var endpoint: TestEndpoint = .{};
    const first = try shell.createSurface(first_client, first_surface, output.id, "first", .top, endpoint.endpoint());
    const second = try shell.createSurface(second_client, second_surface, output.id, "second", .bottom, endpoint.endpoint());
    shell.clientDisconnected(first_client);
    try std.testing.expect(shell.snapshot(first) == null);
    try std.testing.expect(shell.snapshot(second) != null);
    shell.surfaceDestroyed(second_surface);
    try std.testing.expect(shell.snapshot(second) == null);
    try std.testing.expectEqual(@as(usize, 0), endpoint.close_count);
}

test "output teardown closes before ordered destruction" {
    var clients = ClientRegistry.init(std.testing.allocator);
    defer clients.deinit();
    const client = try clients.register(.mature_display);
    defer clients.unregister(client);
    var surfaces = SurfaceRegistry.init(std.testing.allocator);
    defer surfaces.deinit();
    var first_provider: TestProvider = .{};
    var second_provider: TestProvider = .{};
    const first_surface = try surfaces.add(.{ .context = &first_provider, .render_state = TestProvider.renderState });
    defer surfaces.remove(first_surface);
    const second_surface = try surfaces.add(.{ .context = &second_provider, .render_state = TestProvider.renderState });
    defer surfaces.remove(second_surface);
    var output: TestOutput = .{};
    var shell = LayerShell.init(std.testing.allocator, &clients, &surfaces, &output, TestOutput.valid);
    defer shell.deinit();
    var chronology: std.ArrayList(u8) = .empty;
    defer chronology.deinit(std.testing.allocator);
    var first_endpoint: TestEndpoint = .{ .chronology = &chronology };
    var second_endpoint: TestEndpoint = .{ .chronology = &chronology };
    var observer: TestObserver = .{ .chronology = &chronology };
    shell.setObserver(observer.observer());
    defer shell.clearObserver(&observer);
    _ = try shell.createSurface(client, first_surface, output.id, "bar", .top, first_endpoint.endpoint());
    _ = try shell.createSurface(client, second_surface, output.id, "background", .background, second_endpoint.endpoint());
    shell.outputRemoved(output.id);
    try std.testing.expectEqualStrings("cdcd", chronology.items);
    try std.testing.expectEqual(@as(usize, 2), observer.destroy_count);
}
