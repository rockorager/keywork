//! Scanner-backed Wayring ownership slice for wl_compositor, wl_surface,
//! wl_subcompositor/wl_subsurface, and wl_shm.
//!
//! Surfaces use the compositor-wide registry for identity and borrowed render
//! state. Wayring object ownership remains isolated per client; presentation
//! policy is delegated through the minimal optional lifecycle listener.

const WayringCompositor = @This();

const builtin = @import("builtin");
const std = @import("std");
const core = @import("wayring-core-protocol");
const wayring = @import("wayring");
const CopiedBufferSnapshot = @import("../CopiedBufferSnapshot.zig");
const HeadlessSurfaceForest = @import("../HeadlessSurfaceForest.zig");
const Region = @import("../region.zig");
const SurfaceRegistry = @import("../SurfaceRegistry.zig");
const SurfaceFrameCompletion = @import("../SurfaceFrameCompletion.zig");
const render = @import("../render/types.zig");

const server = wayring.server;
const wire = wayring.wire;
const Shm = server.shm.Protocol(core);
const compositor_version = 6;
const preferred_buffer_scale_event_opcode = 2;
const preferred_buffer_transform_event_opcode = 3;

pub const SurfaceId = SurfaceRegistry.Id;

/// Frontend-local delivery endpoint borrowed for one synchronous event fanout.
/// Callers must not retain either pointer or use it after returning to the
/// event loop.
pub const SurfaceEndpoint = struct {
    client: *server.Client,
    resource: *core.wl_surface.Resource,
};

/// Resource-free presentation completion copied by listeners that sample a
/// surface later. `context` is always a WayringCompositor, never a Wayland
/// Resource. Callers must retain the canonical SurfaceId supplied with this
/// value and must not invoke it after compositor deinit; removed or reused IDs
/// are harmless no-ops.
pub const FrameCompletion = SurfaceFrameCompletion;
pub const Position = HeadlessSurfaceForest.Position;
pub const AppliedSurfaceState = HeadlessSurfaceForest.AppliedSurfaceState;
pub const AppliedStackEntry = HeadlessSurfaceForest.AppliedStackEntry;
pub const AppliedParentState = HeadlessSurfaceForest.AppliedParentState;
pub const AppliedBatch = HeadlessSurfaceForest.AppliedBatch;

/// Final synchronous presentation-publication seam copied by init. The context
/// remains borrowed until compositor deinit. Callbacks receive no Wayland
/// resources or policy and must not reenter surface lifecycle. Applied batch
/// slices are valid only for the callback. During creation rollback,
/// `removing` can resolve the provider through SurfaceRegistry even when the
/// Wayring object was not published in its per-client list.
pub const PresentationListener = struct {
    context: *anyopaque,
    added: *const fn (*anyopaque, SurfaceId, FrameCompletion) error{OutOfMemory}!void,
    detached: *const fn (*anyopaque, SurfaceId) void,
    applied: *const fn (*anyopaque, AppliedBatch) void,
    removing: *const fn (*anyopaque, SurfaceId) void,
};

const UpdateToken = struct {
    surface: SurfaceId,
    sequence: u64,
};

const FrameCallback = struct {
    const State = union(enum) {
        pending,
        queued: UpdateToken,
        committed,
    };

    resource: core.wl_callback.Resource,
    state: State,
};

const Surface = struct {
    const Role = enum { none, subsurface, other };
    resource: core.wl_surface.Resource,
    id: SurfaceId,
    destroying: bool = false,
    frame_callbacks: std.ArrayList(*FrameCallback) = .empty,
    pending_attachment: ?PendingAttachment = null,
    has_pending_attachment: bool = false,
    pending_offset_x: i32 = 0,
    pending_offset_y: i32 = 0,
    current_offset_x: i32 = 0,
    current_offset_y: i32 = 0,
    pending_damage: Region,
    pending_opaque: Region,
    pending_opaque_dirty: bool = false,
    current_opaque: Region,
    pending_input: InputRegion,
    pending_input_dirty: bool = false,
    current_input: InputRegion,
    pending_scale: i32 = 1,
    current_scale: i32 = 1,
    pending_transform: render.BufferTransform = .normal,
    current_transform: render.BufferTransform = .normal,
    current: ?CopiedBufferSnapshot = null,
    current_logical_size: ?render.Size = null,
    source_cache_id: u64,
    next_source_version: u64 = 1,
    /// Content-update serials never wrap: aliasing an old dependency is worse
    /// than terminalizing the (already impractically long-lived) client.
    next_content_sequence: ?u64 = 1,
    content_updates: std.ArrayList(ContentUpdate) = .empty,
    relationship: ?Relationship = null,
    role: Role = .none,
    active_subsurface: ?*Subsurface = null,
    children: std.ArrayList(ChildPlacement) = .empty,
    parent_sentinel_index: usize = 0,
    topology_dirty: bool = false,
};

const AssociationIdentity = struct {
    child: SurfaceId,
    parent: SurfaceId,
    generation: u64,
};

const Relationship = struct {
    identity: AssociationIdentity,
    local_sync: bool = true,
    position: Position = .{},
    detached: bool = true,
};

const ChildPlacement = struct {
    identity: AssociationIdentity,
    position: Position = .{},
};

const TopologyEntry = union(enum) {
    parent,
    child: struct {
        identity: AssociationIdentity,
        position: Position,
    },
};

const UpdateKind = enum { scu, dcu };
const Claim = struct {
    token: UpdateToken,
    association: AssociationIdentity,
};

const ContentUpdate = struct {
    token: UpdateToken,
    prepared: PreparedCommit,
    callback_count: usize,
    kind: UpdateKind,
    claims: std.ArrayList(Claim) = .empty,
    claimed_by: ?UpdateToken = null,
    topology: ?std.ArrayList(TopologyEntry) = null,

    fn deinit(self: *ContentUpdate, allocator: std.mem.Allocator) void {
        self.prepared.deinit();
        self.claims.deinit(allocator);
        if (self.topology) |*topology| topology.deinit(allocator);
        self.* = undefined;
    }
};

const ApplyScratch = struct {
    const Visit = struct {
        token: UpdateToken,
        exit: bool,
    };

    visits: std.ArrayList(Visit) = .empty,
    active: std.ArrayList(UpdateToken) = .empty,
    plan: std.ArrayList(UpdateToken) = .empty,
    surfaces: std.ArrayList(AppliedSurfaceState) = .empty,
    parents: std.ArrayList(AppliedParentState) = .empty,
    stack_entries: std.ArrayList(AppliedStackEntry) = .empty,

    fn deinit(self: *ApplyScratch, allocator: std.mem.Allocator) void {
        self.stack_entries.deinit(allocator);
        self.parents.deinit(allocator);
        self.surfaces.deinit(allocator);
        self.plan.deinit(allocator);
        self.active.deinit(allocator);
        self.visits.deinit(allocator);
        self.* = undefined;
    }
};

const DesyncTransition = struct {
    affected: std.ArrayList(SurfaceId) = .empty,
    scratch: ?ApplyScratch = null,

    fn deinit(self: *DesyncTransition, allocator: std.mem.Allocator) void {
        if (self.scratch) |*scratch| scratch.deinit(allocator);
        self.affected.deinit(allocator);
        self.* = undefined;
    }
};

const InputRegion = struct {
    infinite: bool,
    value: Region,

    fn init() InputRegion {
        return .{ .infinite = true, .value = Region.init() };
    }

    fn deinit(self: *InputRegion) void {
        self.value.deinit();
        self.* = undefined;
    }

    fn set(self: *InputRegion, region: *const Region) Region.Error!void {
        try self.value.copyFrom(region);
        self.infinite = false;
    }

    fn setInfinite(self: *InputRegion) void {
        self.value.clear();
        self.infinite = true;
    }

    fn copyFrom(self: *InputRegion, other: *const InputRegion) Region.Error!void {
        try self.value.copyFrom(&other.value);
        self.infinite = other.infinite;
    }
};

/// One fully validated, independently owned candidate publication. The
/// callback count freezes the pending prefix owned by this transaction so
/// later frame requests remain pending if publication is delayed.
const PreparedCommit = struct {
    damage: Region,
    opaque_region: ?Region = null,
    input: ?InputRegion = null,
    buffer: ?CopiedBufferSnapshot = null,
    pending_frame_callback_count: usize,
    attachment_changed: bool,
    publishes_snapshot: bool = false,
    physical_size: ?render.Size = null,
    logical_size: ?render.Size,
    scale: i32,
    transform: render.BufferTransform,
    offset_x: i32,
    offset_y: i32,

    fn init(surface: *const Surface) PreparedCommit {
        return .{
            .damage = Region.init(),
            .pending_frame_callback_count = pendingFrameCallbackCount(surface),
            .attachment_changed = surface.has_pending_attachment,
            .logical_size = surface.current_logical_size,
            .scale = surface.pending_scale,
            .transform = surface.pending_transform,
            .offset_x = surface.pending_offset_x,
            .offset_y = surface.pending_offset_y,
        };
    }

    fn deinit(self: *PreparedCommit) void {
        self.damage.deinit();
        if (self.opaque_region) |*opaque_region| opaque_region.deinit();
        if (self.input) |*input| input.deinit();
        if (self.buffer) |*buffer| buffer.deinit();
        self.* = undefined;
    }
};

const PendingAttachment = struct {
    pin: server.shm.Buffer.Pin,
    resource: ?*server.Resource,
    observer: ?*server.Resource.Observer = null,

    fn bufferDestroyed(self: *PendingAttachment, _: *server.Resource, _: *server.Resource.Observer) void {
        self.resource = null;
        self.observer = null;
    }

    fn deinit(self: *PendingAttachment) void {
        if (self.observer) |observer| server.Resource.removeDestroyObserver(observer);
        self.pin.deinit();
        self.* = undefined;
    }
};

const Compositor = struct {
    resource: core.wl_compositor.Resource,
};

const Subcompositor = struct { resource: core.wl_subcompositor.Resource };
const Subsurface = struct {
    resource: core.wl_subsurface.Resource,
    identity: AssociationIdentity,
};

const RegionResource = struct {
    resource: core.wl_region.Resource,
    value: Region,
};

const ClientObjects = struct {
    client: *server.Client,
    compositors: std.ArrayList(*Compositor) = .empty,
    subcompositors: std.ArrayList(*Subcompositor) = .empty,
    subsurfaces: std.ArrayList(*Subsurface) = .empty,
    surfaces: std.ArrayList(*Surface) = .empty,
    regions: std.ArrayList(*RegionResource) = .empty,
};

const CommitFault = enum {
    queue_storage,
    candidate_allocation,
    prepared_owned,
    region_copy,
    claims,
    topology_snapshot,
    apply_scratch,
    batch_assembly,
    access,
    copy,
    access_end,
    release_enqueue,
};

allocator: std.mem.Allocator,
protocol_server: *server.Server,
surface_registry: *SurfaceRegistry,
presentation_listener: ?PresentationListener,
global: *const server.Server.Global,
subcompositor_global: *const server.Server.Global,
shm: Shm,
clients: std.ArrayList(*ClientObjects) = .empty,
owned_provider_count: usize = 0,
next_relationship_generation: ?u64 = 1,
completing_frame_callbacks: bool = false,
commit_fault: if (builtin.is_test) ?CommitFault else void,

/// Borrows the shared registry and copies the optional presentation listener.
/// Both the registry and listener context must outlive this adapter.
pub fn init(
    self: *WayringCompositor,
    allocator: std.mem.Allocator,
    protocol_server: *server.Server,
    surface_registry: *SurfaceRegistry,
    presentation_listener: ?PresentationListener,
) !void {
    self.* = .{
        .allocator = allocator,
        .protocol_server = protocol_server,
        .surface_registry = surface_registry,
        .presentation_listener = presentation_listener,
        .global = undefined,
        .subcompositor_global = undefined,
        .shm = .init(allocator),
        .completing_frame_callbacks = false,
        .commit_fault = if (builtin.is_test) null else {},
    };
    self.global = try protocol_server.addGlobal(
        core.wl_compositor,
        compositor_version,
        WayringCompositor,
        self,
        bind,
    );
    errdefer protocol_server.removeGlobal(self.global) catch {};
    _ = try self.shm.publish(protocol_server, 1);
    errdefer self.shm.deinit();
    self.subcompositor_global = try self.protocol_server.addGlobal(
        core.wl_subcompositor,
        1,
        WayringCompositor,
        self,
        bindSubcompositor,
    );
}

pub fn deinit(self: *WayringCompositor) void {
    std.debug.assert(self.clients.items.len == 0);
    std.debug.assert(self.owned_provider_count == 0);
    self.protocol_server.removeGlobal(self.subcompositor_global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.shm.deinit();
    self.protocol_server.removeGlobal(self.global) catch |err| switch (err) {
        error.AlreadyRemoved => {},
        error.ForeignGlobal => unreachable,
    };
    self.clients.deinit(self.allocator);
    self.* = undefined;
}

pub fn destroyClientResources(self: *WayringCompositor, client: *server.Client) void {
    for (self.clients.items, 0..) |objects, index| {
        if (objects.client != client) continue;
        while (objects.subsurfaces.items.len > 0)
            self.destroySubsurface(objects.subsurfaces.items[objects.subsurfaces.items.len - 1]);
        while (objects.surfaces.items.len > 0) {
            self.destroySurface(objects.surfaces.items[objects.surfaces.items.len - 1]);
        }
        while (objects.regions.items.len > 0) {
            self.destroyRegion(objects.regions.items[objects.regions.items.len - 1]);
        }
        while (objects.compositors.items.len > 0) {
            self.destroyCompositor(objects.compositors.items[objects.compositors.items.len - 1]);
        }
        while (objects.subcompositors.items.len > 0)
            self.destroySubcompositor(objects.subcompositors.items[objects.subcompositors.items.len - 1]);
        objects.subsurfaces.deinit(self.allocator);
        objects.subcompositors.deinit(self.allocator);
        objects.surfaces.deinit(self.allocator);
        objects.regions.deinit(self.allocator);
        objects.compositors.deinit(self.allocator);
        self.allocator.destroy(objects);
        _ = self.clients.orderedRemove(index);
        break;
    }
    self.shm.destroyClientResources(client);
}

pub fn surfaceCount(self: *const WayringCompositor) usize {
    var count: usize = 0;
    for (self.clients.items) |objects| count += objects.surfaces.items.len;
    return count;
}

pub fn regionCount(self: *const WayringCompositor) usize {
    var count: usize = 0;
    for (self.clients.items) |objects| count += objects.regions.items.len;
    return count;
}

pub fn containsSurface(self: *const WayringCompositor, id: SurfaceId) bool {
    return self.surfaceForId(id) != null;
}

pub fn surfaceEndpoint(self: *WayringCompositor, id: SurfaceId) ?SurfaceEndpoint {
    const surface = self.surfaceForId(id) orelse return null;
    if (surface.destroying or surface.resource.runtime.state() != .live) return null;
    const client = self.clientForResource(&surface.resource.runtime) orelse return null;
    return .{ .client = client, .resource = &surface.resource };
}

pub fn surfaceId(self: *const WayringCompositor, client: *const server.Client, object_id: u32) ?SurfaceId {
    for (self.clients.items) |objects| {
        if (objects.client != client) continue;
        for (objects.surfaces.items) |surface| {
            if (surface.resource.id() == object_id) return surface.id;
        }
        return null;
    }
    return null;
}

pub fn currentBuffer(self: *WayringCompositor, id: SurfaceId) ?*CopiedBufferSnapshot {
    const surface = self.surfaceForId(id) orelse return null;
    return if (surface.current) |*current| current else null;
}

// Private resource-free controls exercise CU relationships without protocol
// state. They deliberately share the production association implementation.
fn testAssociate(self: *WayringCompositor, child_id: SurfaceId, parent_id: SurfaceId) !u64 {
    const child = self.surfaceForId(child_id) orelse return error.UnknownSurface;
    const parent = self.surfaceForId(parent_id) orelse return error.UnknownSurface;
    if ((child.role != .none and child.role != .subsurface) or child.relationship != null or
        std.meta.eql(child_id, parent_id)) return error.BadRelationship;
    var cursor = parent;
    var depth: usize = 0;
    while (true) {
        if (std.meta.eql(cursor.id, child_id)) return error.RelationshipCycle;
        const relationship = cursor.relationship orelse break;
        depth += 1;
        if (depth >= self.surfaceCount()) return error.RelationshipCycle;
        cursor = self.surfaceForId(relationship.identity.parent) orelse return error.BadRelationship;
    }
    const generation = self.next_relationship_generation orelse return error.GenerationExhausted;
    try parent.children.ensureUnusedCapacity(self.allocator, 1);
    const identity: AssociationIdentity = .{
        .child = child_id,
        .parent = parent_id,
        .generation = generation,
    };
    self.publishRelationship(child, parent, identity);
    return generation;
}

fn testSetPosition(self: *WayringCompositor, child_id: SurfaceId, position: Position) !void {
    const child = self.surfaceForId(child_id) orelse return error.UnknownSurface;
    const identity = (child.relationship orelse return error.BadRelationship).identity;
    return self.setRelationshipPosition(child, identity, position);
}

fn testSetSync(self: *WayringCompositor, child_id: SurfaceId) !void {
    const child = self.surfaceForId(child_id) orelse return error.UnknownSurface;
    const identity = (child.relationship orelse return error.BadRelationship).identity;
    const relationship = self.exactRelationship(child, identity) orelse return error.BadRelationship;
    relationship.local_sync = true;
}

fn testSetDesync(self: *WayringCompositor, child_id: SurfaceId) !void {
    const child = self.surfaceForId(child_id) orelse return error.UnknownSurface;
    const identity = (child.relationship orelse return error.BadRelationship).identity;
    return self.setRelationshipDesync(child, identity);
}

fn setRelationshipDesync(self: *WayringCompositor, child: *Surface, identity: AssociationIdentity) !void {
    const relationship = self.exactRelationship(child, identity) orelse return error.BadRelationship;
    if (!relationship.local_sync) return;
    const parent = self.surfaceForId(relationship.identity.parent) orelse return error.BadRelationship;
    if (self.effectivelySynchronized(parent)) {
        relationship.local_sync = false;
        return;
    }

    var transition = try self.prepareDesyncTransition(child, true);
    defer transition.deinit(self.allocator);
    relationship.local_sync = false;
    self.applyDesyncTransition(&transition);
}

/// Prebuilds every allocation needed to convert one newly desynchronized
/// surface or the local-desync descendants exposed by removing an ancestor's
/// role. No modes, claims, queues, or applied state change before this returns.
fn prepareDesyncTransition(
    self: *WayringCompositor,
    start: *Surface,
    include_start: bool,
) !DesyncTransition {
    var transition: DesyncTransition = .{};
    errdefer transition.deinit(self.allocator);
    if (!include_start) {
        const has_local_desync_child = for (start.children.items) |entry| {
            const descendant = self.surfaceForId(entry.identity.child) orelse continue;
            const relationship = descendant.relationship orelse continue;
            if (std.meta.eql(relationship.identity, entry.identity) and !relationship.local_sync) break true;
        } else false;
        if (!has_local_desync_child) return transition;
    }
    var roots: std.ArrayList(UpdateToken) = .empty;
    defer roots.deinit(self.allocator);
    try transition.affected.ensureTotalCapacity(self.allocator, self.surfaceCount());
    try roots.ensureTotalCapacity(self.allocator, self.surfaceCount());
    if (include_start) {
        transition.affected.appendAssumeCapacity(start.id);
    } else {
        for (start.children.items) |entry| {
            const descendant = self.surfaceForId(entry.identity.child) orelse continue;
            const descendant_relationship = descendant.relationship orelse continue;
            if (!std.meta.eql(descendant_relationship.identity, entry.identity) or descendant_relationship.local_sync)
                continue;
            transition.affected.appendAssumeCapacity(descendant.id);
        }
    }
    var index: usize = 0;
    while (index < transition.affected.items.len) : (index += 1) {
        const surface = self.surfaceForId(transition.affected.items[index]) orelse continue;
        if (surface.content_updates.items.len != 0)
            roots.appendAssumeCapacity(surface.content_updates.items[surface.content_updates.items.len - 1].token);
        for (surface.children.items) |entry| {
            const descendant = self.surfaceForId(entry.identity.child) orelse continue;
            const descendant_relationship = descendant.relationship orelse continue;
            if (!std.meta.eql(descendant_relationship.identity, entry.identity) or descendant_relationship.local_sync)
                continue;
            transition.affected.appendAssumeCapacity(descendant.id);
        }
    }

    transition.scratch = if (roots.items.len == 0)
        null
    else
        try self.prepareApplyScratch(roots.items, null);
    return transition;
}

fn applyDesyncTransition(self: *WayringCompositor, transition: *DesyncTransition) void {
    // With no fifo, commit-timing, or explicit-sync constraints in Wave 4B,
    // every converted queue is immediately eligible as a whole. Adding any
    // such constraint invalidates this simplification and requires selecting
    // candidates after constraint evaluation instead.
    for (transition.affected.items) |id| {
        const surface = self.surfaceForId(id) orelse continue;
        for (surface.content_updates.items) |*update| {
            update.kind = .dcu;
            self.unlinkIncomingClaim(update);
        }
    }
    if (transition.scratch) |*scratch| self.applyScratch(scratch);
}

fn testDissociate(self: *WayringCompositor, child_id: SurfaceId) !void {
    const child = self.surfaceForId(child_id) orelse return error.UnknownSurface;
    const identity = (child.relationship orelse return error.BadRelationship).identity;
    var transition = try self.prepareDesyncTransition(child, false);
    defer transition.deinit(self.allocator);
    if (!self.dissociate(child, identity)) return error.BadRelationship;
    self.applyDesyncTransition(&transition);
}

/// Completes every callback committed for the canonical surface ID. Event
/// enqueue failure terminalizes the client but never escapes this entrypoint;
/// each one-shot callback is retired regardless. Pending callbacks are left
/// for a later successful commit.
pub fn completeFrame(self: *WayringCompositor, id: SurfaceId, timestamp_ms: u32) void {
    if (self.completing_frame_callbacks) {
        if (builtin.mode == .Debug) std.debug.assert(false);
        return;
    }
    self.completing_frame_callbacks = true;
    defer self.completing_frame_callbacks = false;

    const surface = self.surfaceForId(id) orelse return;
    if (surface.destroying) return;
    const client = self.clientForResource(&surface.resource.runtime) orelse return;
    while (surface.frame_callbacks.items.len > 0) {
        const callback = surface.frame_callbacks.items[0];
        switch (callback.state) {
            .pending, .queued => break,
            .committed => {},
        }
        core.wl_callback.@"send:done"(&callback.resource, timestamp_ms) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => client.postOutOfMemory(&callback.resource.runtime, "queueing wl_callback.done"),
            error.OutputSealed, error.ClientFatal => {},
            else => client.postImplementationError(&callback.resource.runtime, "queueing wl_callback.done"),
        };
        destroyFrameCallback(self, surface, 0);
    }
}

fn completeFrameThunk(context: *anyopaque, id: SurfaceId, timestamp_ms: u32) void {
    const self: *WayringCompositor = @ptrCast(@alignCast(context));
    self.completeFrame(id, timestamp_ms);
}

fn bind(client: *server.Client, id: u32, version: u32, self: *WayringCompositor) !void {
    const objects = try self.clientObjects(client);
    try objects.compositors.ensureUnusedCapacity(self.allocator, 1);
    const compositor = try self.allocator.create(Compositor);
    errdefer self.allocator.destroy(compositor);
    compositor.* = .{ .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    errdefer {
        compositor.resource.destroy();
        compositor.resource.deinit();
    }
    try compositor.resource.setHandler(WayringCompositor, self, handleCompositor, null);
    try client.materialize(&compositor.resource.runtime);
    objects.compositors.appendAssumeCapacity(compositor);
}

fn bindSubcompositor(client: *server.Client, id: u32, version: u32, self: *WayringCompositor) !void {
    const objects = try self.clientObjects(client);
    const had_storage = objects.subcompositors.capacity != 0;
    try objects.subcompositors.ensureUnusedCapacity(self.allocator, 1);
    errdefer if (!had_storage and objects.subcompositors.items.len == 0) {
        objects.subcompositors.deinit(self.allocator);
        objects.subcompositors = .empty;
    };
    const value = try self.allocator.create(Subcompositor);
    errdefer self.allocator.destroy(value);
    value.* = .{ .resource = .init(self.allocator, id, version, .client, client.ownerHooks()) };
    value.resource.setHandler(WayringCompositor, self, handleSubcompositor, null) catch unreachable;
    client.materialize(&value.resource.runtime) catch unreachable;
    objects.subcompositors.appendAssumeCapacity(value);
}

fn handleSubcompositor(resource: *core.wl_subcompositor.Resource, request: core.wl_subcompositor.Request, self: *WayringCompositor) !void {
    switch (request) {
        .destroy => self.destroySubcompositor(@fieldParentPtr("resource", resource)),
        .get_subsurface => |get| try self.createSubsurface(resource, get.id, get.surface, get.parent),
    }
}

fn adapterSurface(objects: *ClientObjects, resource: *server.Resource) ?*Surface {
    for (objects.surfaces.items) |surface|
        if (&surface.resource.runtime == resource and resource.state() == .live and !surface.destroying) return surface;
    return null;
}

fn createSubsurface(self: *WayringCompositor, manager: *core.wl_subcompositor.Resource, id: u32, child_id: u32, parent_id: u32) !void {
    const client = self.clientForResource(&manager.runtime) orelse return error.UntrackedClient;
    const objects = self.findClient(client) orelse return error.UntrackedClient;
    const child = adapterSurface(objects, client.lookup(child_id) orelse {
        client.postProtocolError(&manager.runtime, @intCast(core.wl_subcompositor.@"error".bad_surface), "invalid child surface");
        return;
    }) orelse {
        client.postProtocolError(&manager.runtime, @intCast(core.wl_subcompositor.@"error".bad_surface), "invalid child surface");
        return;
    };
    const parent = adapterSurface(objects, client.lookup(parent_id) orelse {
        client.postProtocolError(&manager.runtime, @intCast(core.wl_subcompositor.@"error".bad_parent), "invalid parent surface");
        return;
    }) orelse {
        client.postProtocolError(&manager.runtime, @intCast(core.wl_subcompositor.@"error".bad_parent), "invalid parent surface");
        return;
    };
    if ((child.role != .none and child.role != .subsurface) or child.active_subsurface != null or child.relationship != null) {
        client.postProtocolError(&manager.runtime, @intCast(core.wl_subcompositor.@"error".bad_surface), "surface already has a role");
        return;
    }
    if (child == parent or self.wouldCreateCycle(child, parent)) {
        client.postProtocolError(&manager.runtime, @intCast(core.wl_subcompositor.@"error".bad_parent), "parent creates a cycle");
        return;
    }
    const generation = self.next_relationship_generation orelse return error.GenerationExhausted;
    const had_subsurface_storage = objects.subsurfaces.capacity != 0;
    try objects.subsurfaces.ensureUnusedCapacity(self.allocator, 1);
    errdefer if (!had_subsurface_storage and objects.subsurfaces.items.len == 0) {
        objects.subsurfaces.deinit(self.allocator);
        objects.subsurfaces = .empty;
    };
    const had_children_storage = parent.children.capacity != 0;
    try parent.children.ensureUnusedCapacity(self.allocator, 1);
    errdefer if (!had_children_storage and parent.children.items.len == 0) {
        parent.children.deinit(self.allocator);
        parent.children = .empty;
    };
    const value = try self.allocator.create(Subsurface);
    errdefer self.allocator.destroy(value);
    const identity: AssociationIdentity = .{ .child = child.id, .parent = parent.id, .generation = generation };
    value.* = .{ .resource = .init(self.allocator, id, 1, .client, client.ownerHooks()), .identity = identity };
    value.resource.setHandler(WayringCompositor, self, handleSubsurface, null) catch unreachable;
    client.materialize(&value.resource.runtime) catch unreachable;
    self.publishRelationship(child, parent, identity);
    child.active_subsurface = value;
    objects.subsurfaces.appendAssumeCapacity(value);
}

fn publishRelationship(self: *WayringCompositor, child: *Surface, parent: *Surface, identity: AssociationIdentity) void {
    self.next_relationship_generation = if (identity.generation == std.math.maxInt(u64)) null else identity.generation + 1;
    child.role = .subsurface;
    child.relationship = .{ .identity = identity };
    parent.children.appendAssumeCapacity(.{ .identity = identity });
    parent.topology_dirty = true;
    if (self.presentation_listener) |listener| listener.detached(listener.context, child.id);
}

fn exactRelationship(self: *WayringCompositor, child: *Surface, identity: AssociationIdentity) ?*Relationship {
    _ = self;
    const relationship = if (child.relationship) |*value| value else return null;
    return if (std.meta.eql(relationship.identity, identity)) relationship else null;
}

fn wouldCreateCycle(self: *WayringCompositor, child: *Surface, parent: *Surface) bool {
    var cursor = parent;
    var depth: usize = 0;
    while (true) {
        if (cursor == child) return true;
        const relationship = cursor.relationship orelse return false;
        cursor = self.surfaceForId(relationship.identity.parent) orelse return false;
        depth += 1;
        if (depth >= self.surfaceCount()) return true;
    }
}

fn handleSubsurface(resource: *core.wl_subsurface.Resource, request: core.wl_subsurface.Request, self: *WayringCompositor) !void {
    const value: *Subsurface = @fieldParentPtr("resource", resource);
    if (request == .destroy) {
        try self.destroySubsurfaceRequest(value);
        return;
    }
    const child = self.surfaceForId(value.identity.child) orelse return;
    const parent = self.surfaceForId(value.identity.parent) orelse return;
    const relationship = self.exactRelationship(child, value.identity) orelse return;
    if (child.active_subsurface != value) return;
    switch (request) {
        .destroy => unreachable,
        .set_position => |set| try self.setRelationshipPosition(child, value.identity, .{ .x = set.x, .y = set.y }),
        .place_above => |place| self.restackSubsurface(value, child, parent, place.sibling, true),
        .place_below => |place| self.restackSubsurface(value, child, parent, place.sibling, false),
        .set_sync => relationship.local_sync = true,
        .set_desync => try self.setRelationshipDesync(child, value.identity),
    }
}

fn destroySubsurfaceRequest(self: *WayringCompositor, value: *Subsurface) !void {
    const child = self.surfaceForId(value.identity.child) orelse {
        self.destroySubsurface(value);
        return;
    };
    if (child.active_subsurface != value or self.exactRelationship(child, value.identity) == null) {
        self.destroySubsurface(value);
        return;
    }
    var transition = try self.prepareDesyncTransition(child, false);
    defer transition.deinit(self.allocator);
    self.destroySubsurface(value);
    self.applyDesyncTransition(&transition);
}

fn setRelationshipPosition(
    self: *WayringCompositor,
    child: *Surface,
    identity: AssociationIdentity,
    position: Position,
) !void {
    const relationship = self.exactRelationship(child, identity) orelse return error.BadRelationship;
    const parent = self.surfaceForId(identity.parent) orelse return error.BadRelationship;
    for (parent.children.items) |*entry| if (std.meta.eql(entry.identity, identity)) {
        relationship.position = position;
        entry.position = position;
        parent.topology_dirty = true;
        return;
    };
    return error.BadRelationship;
}

fn restackSubsurface(self: *WayringCompositor, value: *Subsurface, child: *Surface, parent: *Surface, sibling_id: u32, above: bool) void {
    const resource = &value.resource;
    const client = self.clientForResource(&resource.runtime) orelse return;
    const objects = self.findClient(client) orelse return;
    const sibling_resource = client.lookup(sibling_id) orelse return self.badSubsurface(client, resource);
    const sibling = adapterSurface(objects, sibling_resource) orelse return self.badSubsurface(client, resource);
    if (sibling == child) return self.badSubsurface(client, resource);
    var old: ?usize = null;
    for (parent.children.items, 0..) |entry, index| if (std.meta.eql(entry.identity, value.identity)) {
        old = index;
        break;
    };
    const old_index = old orelse return self.badSubsurface(client, resource);
    var sentinel = parent.parent_sentinel_index;
    if (old_index < sentinel) sentinel -= 1;
    var target: usize = undefined;
    var inserted_below_parent = false;
    if (sibling == parent) target = sentinel else {
        const relationship = sibling.relationship orelse return self.badSubsurface(client, resource);
        if (!std.meta.eql(relationship.identity.parent, parent.id)) return self.badSubsurface(client, resource);
        const sibling_role = sibling.active_subsurface orelse return self.badSubsurface(client, resource);
        if (!std.meta.eql(sibling_role.identity, relationship.identity)) return self.badSubsurface(client, resource);
        const sibling_index = for (parent.children.items, 0..) |entry, index| {
            if (std.meta.eql(entry.identity, relationship.identity)) {
                var adjusted = index;
                if (old_index < adjusted) adjusted -= 1;
                break adjusted;
            }
        } else return self.badSubsurface(client, resource);
        inserted_below_parent = sibling_index < sentinel;
        target = if (above) sibling_index + 1 else sibling_index;
    }
    const entry = parent.children.orderedRemove(old_index);
    parent.children.insertAssumeCapacity(target, entry);
    if (sibling == parent) {
        if (!above) sentinel += 1;
    } else if (inserted_below_parent) sentinel += 1;
    parent.parent_sentinel_index = sentinel;
    parent.topology_dirty = true;
}

fn badSubsurface(self: *WayringCompositor, client: *server.Client, resource: *core.wl_subsurface.Resource) void {
    _ = self;
    client.postProtocolError(&resource.runtime, @intCast(core.wl_subsurface.@"error".bad_surface), "invalid placement reference");
}

fn handleCompositor(
    resource: *core.wl_compositor.Resource,
    request: core.wl_compositor.Request,
    self: *WayringCompositor,
) !void {
    switch (request) {
        .create_surface => |create| try self.createSurface(resource, create.id),
        .create_region => |create| try self.createRegion(resource, create.id),
        .release => self.destroyCompositor(@fieldParentPtr("resource", resource)),
    }
}

fn createSurface(self: *WayringCompositor, compositor: *core.wl_compositor.Resource, object_id: u32) !void {
    const client = self.clientForResource(&compositor.runtime) orelse return error.UntrackedClient;
    const objects = self.findClient(client) orelse return error.UntrackedClient;
    const surface = try self.allocator.create(Surface);
    errdefer self.allocator.destroy(surface);
    surface.* = .{
        .resource = undefined,
        .id = undefined,
        .pending_damage = .init(),
        .pending_opaque = .init(),
        .current_opaque = .init(),
        .pending_input = .init(),
        .current_input = .init(),
        .source_cache_id = render.allocateSourceCacheId(),
    };
    errdefer {
        surface.current_input.deinit();
        surface.pending_input.deinit();
        surface.current_opaque.deinit();
        surface.pending_opaque.deinit();
        surface.pending_damage.deinit();
    }
    surface.id = try self.surface_registry.add(.{
        .context = surface,
        .render_state = surfaceRenderState,
    });
    self.owned_provider_count += 1;
    errdefer {
        self.surface_registry.remove(surface.id);
        self.owned_provider_count -= 1;
    }
    var listener_added = false;
    errdefer if (listener_added) {
        const listener = self.presentation_listener.?;
        listener.removing(listener.context, surface.id);
    };
    if (self.presentation_listener) |listener| {
        try listener.added(listener.context, surface.id, .{
            .context = self,
            .complete = completeFrameThunk,
        });
        listener_added = true;
    }
    try objects.surfaces.ensureUnusedCapacity(self.allocator, 1);
    surface.resource = .init(self.allocator, object_id, compositor.version(), .client, client.ownerHooks());
    surface.resource.setHandler(WayringCompositor, self, handleSurface, null) catch unreachable;
    // Dispatch reserved and type-checked this new_id before calling us;
    // materialization only replaces that reservation and cannot allocate.
    client.materialize(&surface.resource.runtime) catch unreachable;
    objects.surfaces.appendAssumeCapacity(surface);
    sendInitialSurfacePreferences(client, surface);
}

fn sendInitialSurfacePreferences(
    client: *server.Client,
    surface: *Surface,
) void {
    const scale_event = core.wl_surface.event_messages[preferred_buffer_scale_event_opcode];
    const transform_event = core.wl_surface.event_messages[preferred_buffer_transform_event_opcode];
    std.debug.assert(scale_event.since == compositor_version);
    std.debug.assert(transform_event.since == compositor_version);
    if (surface.resource.version() < scale_event.since) return;

    // The object is already materialized and published in the per-client list.
    // A queue failure terminalizes the client while preserving that ownership;
    // normal client teardown then removes the listener, provider, and resource.
    core.wl_surface.@"send:preferred_buffer_scale"(&surface.resource, 1) catch |err| {
        classifyPreferenceEventFailure(client, &surface.resource.runtime, err);
        return;
    };
    core.wl_surface.@"send:preferred_buffer_transform"(
        &surface.resource,
        @intCast(core.wl_output.transform.normal),
    ) catch |err| classifyPreferenceEventFailure(client, &surface.resource.runtime, err);
}

fn classifyPreferenceEventFailure(
    client: *server.Client,
    resource: *server.Resource,
    err: anyerror,
) void {
    switch (err) {
        error.OutOfMemory, error.WriteFailed => client.postOutOfMemory(resource, "queueing initial wl_surface preferences"),
        error.OutputSealed, error.ClientFatal => {},
        else => client.postImplementationError(resource, "queueing initial wl_surface preferences"),
    }
}

fn createRegion(self: *WayringCompositor, compositor: *core.wl_compositor.Resource, object_id: u32) !void {
    const client = self.clientForResource(&compositor.runtime) orelse return error.UntrackedClient;
    const objects = self.findClient(client) orelse return error.UntrackedClient;
    try objects.regions.ensureUnusedCapacity(self.allocator, 1);
    const region = try self.allocator.create(RegionResource);
    errdefer self.allocator.destroy(region);
    region.* = .{
        .resource = .init(self.allocator, object_id, compositor.version(), .client, client.ownerHooks()),
        .value = .init(),
    };
    errdefer {
        region.value.deinit();
        region.resource.destroy();
        region.resource.deinit();
    }
    try region.resource.setHandler(WayringCompositor, self, handleRegion, null);
    try client.materialize(&region.resource.runtime);
    objects.regions.appendAssumeCapacity(region);
}

fn surfaceRenderState(context: *anyopaque) ?SurfaceRegistry.RenderState {
    const surface: *Surface = @ptrCast(@alignCast(context));
    const current = if (surface.current) |*snapshot| snapshot else return null;
    return .{
        .buffer = current.pixelBuffer(.{}, .{}),
        .logical_size = surface.current_logical_size.?,
        .source = null,
        .transform = surface.current_transform,
        .force_opaque = current.forceOpaque(),
        .alpha_multiplier = std.math.maxInt(u32),
        .opaque_region = &surface.current_opaque,
        .blur_region = null,
    };
}

fn handleSurface(
    resource: *core.wl_surface.Resource,
    request: core.wl_surface.Request,
    self: *WayringCompositor,
) !void {
    switch (request) {
        .destroy => {
            const surface: *Surface = @fieldParentPtr("resource", resource);
            if (surface.active_subsurface != null) {
                const client = self.clientForResource(&resource.runtime) orelse return error.UntrackedClient;
                client.postProtocolError(&resource.runtime, @intCast(core.wl_surface.@"error".defunct_role_object), "surface has a live role object");
                return;
            }
            self.destroySurface(surface);
        },
        .attach => |attach| try self.attachSurface(resource, attach.buffer, attach.x, attach.y),
        .damage => |damage| {
            if (damage.width > 0 and damage.height > 0) {
                const surface: *Surface = @fieldParentPtr("resource", resource);
                surface.pending_damage.add(damage.x, damage.y, damage.width, damage.height) catch {
                    const client = self.clientForResource(&resource.runtime) orelse return error.UntrackedClient;
                    client.postOutOfMemory(&resource.runtime, "adding wl_surface damage");
                };
            }
        },
        .frame => |frame| try self.frameSurface(resource, frame.callback),
        .set_opaque_region => |set| self.setOpaqueRegion(resource, set.region),
        .set_input_region => |set| self.setInputRegion(resource, set.region),
        .commit => try self.commitSurface(@fieldParentPtr("resource", resource)),
        .set_buffer_transform => |set| {
            const transform = bufferTransform(set.transform) orelse {
                const client = self.clientForResource(&resource.runtime) orelse return error.UntrackedClient;
                client.postProtocolError(
                    &resource.runtime,
                    @intCast(core.wl_surface.@"error".invalid_transform),
                    "invalid buffer transform",
                );
                return;
            };
            const surface: *Surface = @fieldParentPtr("resource", resource);
            surface.pending_transform = transform;
        },
        .set_buffer_scale => |set| {
            if (set.scale <= 0) {
                const client = self.clientForResource(&resource.runtime) orelse return error.UntrackedClient;
                client.postProtocolError(
                    &resource.runtime,
                    @intCast(core.wl_surface.@"error".invalid_scale),
                    "buffer scale must be positive",
                );
                return;
            }
            const surface: *Surface = @fieldParentPtr("resource", resource);
            surface.pending_scale = set.scale;
        },
        .damage_buffer => |damage| {
            if (damage.width <= 0 or damage.height <= 0) return;
            // Buffer-coordinate damage must not be merged into the
            // surface-coordinate pending_damage region. Phase 2 copies every
            // new SHM snapshot in full and presentation conservatively damages
            // the full old and new root bounds for every successful commit, so
            // this advisory rectangle has no incremental consumer yet.
        },
        .offset => |offset| {
            const surface: *Surface = @fieldParentPtr("resource", resource);
            surface.pending_offset_x = offset.x;
            surface.pending_offset_y = offset.y;
        },
        else => {
            const client = self.clientForResource(&resource.runtime) orelse return error.UntrackedClient;
            client.postImplementationError(&resource.runtime, "wl_surface request is not implemented by the Wayring backend");
        },
    }
}

fn bufferTransform(transform: i32) ?render.BufferTransform {
    return switch (transform) {
        @as(i32, @intCast(core.wl_output.transform.normal)) => .normal,
        @as(i32, @intCast(core.wl_output.transform.@"90")) => .rotate_90,
        @as(i32, @intCast(core.wl_output.transform.@"180")) => .rotate_180,
        @as(i32, @intCast(core.wl_output.transform.@"270")) => .rotate_270,
        @as(i32, @intCast(core.wl_output.transform.flipped)) => .flipped,
        @as(i32, @intCast(core.wl_output.transform.flipped_90)) => .flipped_90,
        @as(i32, @intCast(core.wl_output.transform.flipped_180)) => .flipped_180,
        @as(i32, @intCast(core.wl_output.transform.flipped_270)) => .flipped_270,
        else => null,
    };
}

fn frameSurface(
    self: *WayringCompositor,
    resource: *core.wl_surface.Resource,
    callback_id: u32,
) !void {
    const client = self.clientForResource(&resource.runtime) orelse return error.UntrackedClient;
    const surface: *Surface = @fieldParentPtr("resource", resource);
    const had_callback_storage = surface.frame_callbacks.capacity != 0;
    try surface.frame_callbacks.ensureUnusedCapacity(self.allocator, 1);
    errdefer if (!had_callback_storage and surface.frame_callbacks.items.len == 0) {
        surface.frame_callbacks.deinit(self.allocator);
        surface.frame_callbacks = .empty;
    };
    const callback = try self.allocator.create(FrameCallback);
    errdefer self.allocator.destroy(callback);
    const callback_version = @min(resource.version(), core.wl_callback.interface.version);
    std.debug.assert(callback_version == 1);
    callback.* = .{
        .resource = .init(self.allocator, callback_id, callback_version, .client, client.ownerHooks()),
        .state = .pending,
    };
    // Dispatch has already reserved and type-checked this new_id. Materialize
    // before publishing the pointer; no fallible work remains afterward.
    client.materialize(&callback.resource.runtime) catch unreachable;
    surface.frame_callbacks.appendAssumeCapacity(callback);
}

fn handleRegion(
    resource: *core.wl_region.Resource,
    request: core.wl_region.Request,
    self: *WayringCompositor,
) !void {
    const region: *RegionResource = @fieldParentPtr("resource", resource);
    switch (request) {
        .destroy => self.destroyRegion(region),
        .add => |add| region.value.add(add.x, add.y, add.width, add.height) catch {
            const client = self.clientForResource(&resource.runtime) orelse return error.UntrackedClient;
            client.postOutOfMemory(&resource.runtime, "adding to wl_region");
        },
        .subtract => |subtract| region.value.subtract(
            subtract.x,
            subtract.y,
            subtract.width,
            subtract.height,
        ) catch {
            const client = self.clientForResource(&resource.runtime) orelse return error.UntrackedClient;
            client.postOutOfMemory(&resource.runtime, "subtracting from wl_region");
        },
    }
}

fn setOpaqueRegion(self: *WayringCompositor, resource: *core.wl_surface.Resource, region_id: ?u32) void {
    const surface: *Surface = @fieldParentPtr("resource", resource);
    const id = region_id orelse {
        surface.pending_opaque.clear();
        surface.pending_opaque_dirty = true;
        return;
    };
    const source = self.resolveRegion(resource, id) orelse return;
    var candidate = Region.init();
    candidate.copyFrom(&source.value) catch {
        candidate.deinit();
        const client = self.clientForResource(&resource.runtime) orelse return;
        client.postOutOfMemory(&resource.runtime, "copying wl_surface opaque region");
        return;
    };
    std.mem.swap(Region, &surface.pending_opaque, &candidate);
    candidate.deinit();
    surface.pending_opaque_dirty = true;
}

fn setInputRegion(self: *WayringCompositor, resource: *core.wl_surface.Resource, region_id: ?u32) void {
    const surface: *Surface = @fieldParentPtr("resource", resource);
    const id = region_id orelse {
        surface.pending_input.setInfinite();
        surface.pending_input_dirty = true;
        return;
    };
    const source = self.resolveRegion(resource, id) orelse return;
    var candidate = InputRegion.init();
    candidate.set(&source.value) catch {
        candidate.deinit();
        const client = self.clientForResource(&resource.runtime) orelse return;
        client.postOutOfMemory(&resource.runtime, "copying wl_surface input region");
        return;
    };
    std.mem.swap(InputRegion, &surface.pending_input, &candidate);
    candidate.deinit();
    surface.pending_input_dirty = true;
}

fn resolveRegion(
    self: *WayringCompositor,
    surface: *core.wl_surface.Resource,
    object_id: u32,
) ?*RegionResource {
    const client = self.clientForResource(&surface.runtime) orelse return null;
    const object = client.lookup(object_id) orelse return null;
    const objects = self.findClient(client) orelse return null;
    for (objects.regions.items) |region| {
        if (&region.resource.runtime == object and object.state() == .live) return region;
    }
    client.postImplementationError(&surface.runtime, "wl_surface region is not a live Wayring wl_region");
    return null;
}

fn attachSurface(
    self: *WayringCompositor,
    resource: *core.wl_surface.Resource,
    buffer_id: ?u32,
    x: i32,
    y: i32,
) !void {
    const client = self.clientForResource(&resource.runtime) orelse return error.UntrackedClient;
    const surface: *Surface = @fieldParentPtr("resource", resource);
    if (resource.version() >= 5 and (x != 0 or y != 0)) {
        client.postProtocolError(&resource.runtime, core.wl_surface.@"error".invalid_offset, "attach offset requires wl_surface.offset");
        return;
    }
    clearPendingAttachment(surface);
    surface.has_pending_attachment = true;
    if (resource.version() < 5) {
        surface.pending_offset_x = x;
        surface.pending_offset_y = y;
    }
    const id = buffer_id orelse return;
    const buffer_resource = client.lookup(id) orelse {
        client.postImplementationError(&resource.runtime, "wl_surface.attach references an unknown buffer");
        return;
    };
    const pin = self.shm.pin(buffer_resource) orelse {
        client.postImplementationError(&resource.runtime, "wl_surface.attach supports only Wayring wl_shm buffers");
        return;
    };
    surface.pending_attachment = .{ .pin = pin, .resource = buffer_resource };
    errdefer {
        surface.pending_attachment.?.deinit();
        surface.pending_attachment = null;
    }
    surface.pending_attachment.?.observer = try buffer_resource.addDestroyObserver(
        PendingAttachment,
        &surface.pending_attachment.?,
        PendingAttachment.bufferDestroyed,
    );
}

fn commitSurface(self: *WayringCompositor, surface: *Surface) !void {
    const had_pending_attachment = surface.has_pending_attachment;
    var published = false;
    // Every preparation failure terminalizes the client. Consume only pending
    // attachment ownership so its observer and pin cannot outlive teardown;
    // no release is sent for a buffer whose transaction was never published.
    // Offset and other pending protocol state remain intact, while applied
    // state remains unchanged, matching the existing terminal policy.
    defer if (!published and had_pending_attachment) clearPendingAttachment(surface);

    const sequence = surface.next_content_sequence orelse {
        const client = self.clientForResource(&surface.resource.runtime) orelse return error.UntrackedClient;
        client.postImplementationError(&surface.resource.runtime, "wl_surface content-update sequence exhausted");
        return;
    };
    const token: UpdateToken = .{ .surface = surface.id, .sequence = sequence };
    // Classification is frozen at the commit request, before preparation.
    const kind: UpdateKind = if (self.effectivelySynchronized(surface)) .scu else .dcu;

    var prepared = self.prepareCommit(surface) catch |err| {
        const client = self.clientForResource(&surface.resource.runtime) orelse return error.UntrackedClient;
        switch (err) {
            error.OutOfMemory => client.postOutOfMemory(
                &surface.resource.runtime,
                "preparing wl_surface commit",
            ),
            error.InvalidSize => client.postProtocolError(
                &surface.resource.runtime,
                @intCast(core.wl_surface.@"error".invalid_size),
                "buffer dimensions are incompatible with surface state",
            ),
            else => client.postImplementationError(&surface.resource.runtime, @errorName(err)),
        }
        return;
    };
    var candidate: ContentUpdate = .{
        .token = token,
        .prepared = prepared,
        .callback_count = prepared.pending_frame_callback_count,
        .kind = kind,
    };
    prepared = undefined;
    var candidate_owned = true;
    defer if (candidate_owned) candidate.deinit(self.allocator);

    if (self.failCommitAt(.queue_storage)) return error.OutOfMemory;
    try surface.content_updates.ensureUnusedCapacity(self.allocator, 1);
    if (self.failCommitAt(.claims)) return error.OutOfMemory;
    try candidate.claims.ensureTotalCapacity(self.allocator, surface.children.items.len);
    for (surface.children.items) |child_entry| {
        const child = self.surfaceForId(child_entry.identity.child) orelse continue;
        if (child.content_updates.items.len == 0) continue;
        const tail = &child.content_updates.items[child.content_updates.items.len - 1];
        const association = child.relationship orelse continue;
        if (tail.kind == .scu and tail.claimed_by == null and
            std.meta.eql(association.identity, child_entry.identity))
        {
            candidate.claims.appendAssumeCapacity(.{
                .token = tail.token,
                .association = association.identity,
            });
        }
    }
    if (self.failCommitAt(.topology_snapshot)) return error.OutOfMemory;
    if (surface.topology_dirty or surface.children.items.len != 0) {
        var value: std.ArrayList(TopologyEntry) = .empty;
        var value_owned = true;
        errdefer if (value_owned) value.deinit(self.allocator);
        try value.ensureTotalCapacity(self.allocator, surface.children.items.len + 1);
        for (surface.children.items[0..surface.parent_sentinel_index]) |child| value.appendAssumeCapacity(.{ .child = .{
            .identity = child.identity,
            .position = child.position,
        } });
        value.appendAssumeCapacity(.parent);
        for (surface.children.items[surface.parent_sentinel_index..]) |child| value.appendAssumeCapacity(.{ .child = .{
            .identity = child.identity,
            .position = child.position,
        } });
        candidate.topology = value;
        value_owned = false;
    }

    var scratch: ?ApplyScratch = null;
    defer if (scratch) |*value| value.deinit(self.allocator);
    if (kind == .dcu and !hasQueuedScu(surface))
        scratch = try self.prepareApplyScratch(&.{token}, &candidate);

    // Release enqueue is the final fallible operation. Queue, callbacks,
    // pending state, claims, and applied state are untouched before it.
    if (surface.pending_attachment) |*pending| if (pending.resource) |buffer_resource| {
        if (self.failCommitAt(.release_enqueue)) return error.OutOfMemory;
        try self.shm.sendRelease(buffer_resource);
    };

    surface.next_content_sequence = std.math.add(u64, sequence, 1) catch null;
    var callbacks_to_queue = candidate.callback_count;
    for (surface.frame_callbacks.items) |callback| switch (callback.state) {
        .pending => if (callbacks_to_queue != 0) {
            callback.state = .{ .queued = token };
            callbacks_to_queue -= 1;
        },
        .queued, .committed => {},
    };
    std.debug.assert(callbacks_to_queue == 0);
    const publishes_snapshot = candidate.prepared.publishes_snapshot;
    surface.content_updates.appendAssumeCapacity(candidate);
    candidate_owned = false;
    const stored = &surface.content_updates.items[surface.content_updates.items.len - 1];
    for (stored.claims.items) |claim| {
        const claimed = self.updateForToken(claim.token) orelse unreachable;
        std.debug.assert(claimed.claimed_by == null);
        claimed.claimed_by = token;
    }

    surface.pending_damage.clear();
    surface.pending_opaque_dirty = false;
    surface.pending_input_dirty = false;
    clearPendingAttachment(surface);
    clearPendingOffset(surface);
    surface.topology_dirty = false;
    if (publishes_snapshot) surface.next_source_version +%= 1;
    published = true;
    if (scratch) |*value| self.applyScratch(value);
    if (surface.relationship == null) std.debug.assert(surface.content_updates.items.len == 0);
}

fn projectedPhysicalSize(self: *WayringCompositor, surface: *const Surface) ?render.Size {
    _ = self;
    var index = surface.content_updates.items.len;
    while (index > 0) {
        index -= 1;
        const prepared = &surface.content_updates.items[index].prepared;
        if (!prepared.attachment_changed) continue;
        return prepared.physical_size;
    }
    return if (surface.current) |*current| current.size else null;
}

fn updateForToken(self: *WayringCompositor, token: UpdateToken) ?*ContentUpdate {
    const surface = self.surfaceForId(token.surface) orelse return null;
    for (surface.content_updates.items) |*update|
        if (std.meta.eql(update.token, token)) return update;
    return null;
}

fn updateForPlan(
    self: *WayringCompositor,
    token: UpdateToken,
    proposed: ?*const ContentUpdate,
) ?*const ContentUpdate {
    if (proposed) |candidate| if (std.meta.eql(candidate.token, token)) return candidate;
    return self.updateForToken(token);
}

fn effectivelySynchronized(self: *WayringCompositor, surface: *const Surface) bool {
    var cursor = surface;
    var remaining = self.surfaceCount() + 1;
    while (cursor.relationship) |relationship| {
        if (remaining == 0) return true;
        remaining -= 1;
        if (relationship.local_sync) return true;
        cursor = self.surfaceForId(relationship.identity.parent) orelse return false;
    }
    return false;
}

fn tokenIn(items: []const UpdateToken, token: UpdateToken) bool {
    for (items) |candidate| if (std.meta.eql(candidate, token)) return true;
    return false;
}

fn hasQueuedScu(surface: *const Surface) bool {
    for (surface.content_updates.items) |update| if (update.kind == .scu) return true;
    return false;
}

fn predecessorToken(
    self: *WayringCompositor,
    token: UpdateToken,
    proposed: ?*const ContentUpdate,
) ?UpdateToken {
    const surface = self.surfaceForId(token.surface) orelse return null;
    if (proposed) |candidate| if (std.meta.eql(candidate.token, token)) {
        return if (surface.content_updates.items.len == 0)
            null
        else
            surface.content_updates.items[surface.content_updates.items.len - 1].token;
    };
    for (surface.content_updates.items, 0..) |update, index| {
        if (!std.meta.eql(update.token, token)) continue;
        return if (index == 0) null else surface.content_updates.items[index - 1].token;
    }
    return null;
}

/// Prebuilds a bounded, nonrecursive post-order plan and every borrowed batch
/// buffer. The optional candidate has not entered its queue yet, allowing CU
/// cycles and allocation failures to be rejected before buffer release.
fn prepareApplyScratch(
    self: *WayringCompositor,
    roots: []const UpdateToken,
    proposed: ?*const ContentUpdate,
) !ApplyScratch {
    var total: usize = 0;
    var topology_entries: usize = 0;
    for (self.clients.items) |objects| {
        for (objects.surfaces.items) |surface| {
            total = try std.math.add(usize, total, surface.content_updates.items.len);
            for (surface.content_updates.items) |update| {
                if (update.topology) |topology|
                    topology_entries = try std.math.add(usize, topology_entries, topology.items.len);
            }
        }
    }
    if (proposed) |candidate| {
        total = try std.math.add(usize, total, 1);
        if (candidate.topology) |topology|
            topology_entries = try std.math.add(usize, topology_entries, topology.items.len);
    }
    const visit_capacity = try std.math.mul(usize, total, 4);

    var scratch: ApplyScratch = .{};
    errdefer scratch.deinit(self.allocator);
    if (self.failCommitAt(.apply_scratch)) return error.OutOfMemory;
    try scratch.visits.ensureTotalCapacity(self.allocator, visit_capacity);
    try scratch.active.ensureTotalCapacity(self.allocator, total);
    try scratch.plan.ensureTotalCapacity(self.allocator, total);
    if (self.failCommitAt(.batch_assembly)) return error.OutOfMemory;
    try scratch.surfaces.ensureTotalCapacity(self.allocator, self.surfaceCount());
    try scratch.parents.ensureTotalCapacity(self.allocator, self.surfaceCount());
    try scratch.stack_entries.ensureTotalCapacity(self.allocator, topology_entries);

    for (roots) |root| {
        scratch.visits.appendAssumeCapacity(.{ .token = root, .exit = false });
        while (scratch.visits.pop()) |visit| {
            if (visit.exit) {
                std.debug.assert(scratch.active.items.len != 0);
                std.debug.assert(std.meta.eql(scratch.active.items[scratch.active.items.len - 1], visit.token));
                _ = scratch.active.pop();
                if (!tokenIn(scratch.plan.items, visit.token)) scratch.plan.appendAssumeCapacity(visit.token);
                continue;
            }
            if (tokenIn(scratch.plan.items, visit.token)) continue;
            if (tokenIn(scratch.active.items, visit.token)) return error.InvalidDependencyCycle;
            const update = self.updateForPlan(visit.token, proposed) orelse return error.InvalidDependencyToken;
            scratch.active.appendAssumeCapacity(visit.token);
            scratch.visits.appendAssumeCapacity(.{ .token = visit.token, .exit = true });
            var claim_index = update.claims.items.len;
            while (claim_index > 0) {
                claim_index -= 1;
                scratch.visits.appendAssumeCapacity(.{
                    .token = update.claims.items[claim_index].token,
                    .exit = false,
                });
            }
            if (self.predecessorToken(visit.token, proposed)) |predecessor|
                scratch.visits.appendAssumeCapacity(.{ .token = predecessor, .exit = false });
        }
    }
    std.debug.assert(scratch.active.items.len == 0);
    return scratch;
}

fn associationLive(
    self: *WayringCompositor,
    parent: SurfaceId,
    identity: AssociationIdentity,
) bool {
    if (!std.meta.eql(parent, identity.parent)) return false;
    const child = self.surfaceForId(identity.child) orelse return false;
    const relationship = child.relationship orelse return false;
    return std.meta.eql(relationship.identity, identity);
}

fn applyScratch(self: *WayringCompositor, scratch: *ApplyScratch) void {
    for (scratch.plan.items) |token| {
        const update = self.updateForToken(token) orelse unreachable;
        const surface = self.surfaceForId(token.surface) orelse unreachable;
        self.publishPreparedCommit(surface, &update.prepared, token, false);

        var state_found = false;
        for (scratch.surfaces.items) |*state| if (std.meta.eql(state.id, surface.id)) {
            state.mapped_size = surface.current_logical_size;
            state.callbacks_committed = state.callbacks_committed or update.callback_count != 0;
            state_found = true;
            break;
        };
        if (!state_found) scratch.surfaces.appendAssumeCapacity(.{
            .id = surface.id,
            .mapped_size = surface.current_logical_size,
            .callbacks_committed = update.callback_count != 0,
        });

        if (update.topology) |topology| {
            const start = scratch.stack_entries.items.len;
            for (topology.items) |entry| switch (entry) {
                .parent => scratch.stack_entries.appendAssumeCapacity(.parent),
                .child => |child| if (self.associationLive(surface.id, child.identity)) {
                    if (self.surfaceForId(child.identity.child)) |live_child| {
                        if (live_child.relationship) |*relationship| relationship.detached = false;
                    }
                    scratch.stack_entries.appendAssumeCapacity(.{ .child = .{
                        .id = child.identity.child,
                        .position = child.position,
                    } });
                },
            };
            const stack = scratch.stack_entries.items[start..];
            var parent_found = false;
            for (scratch.parents.items) |*parent_state| if (std.meta.eql(parent_state.id, surface.id)) {
                parent_state.stack = stack;
                parent_found = true;
                break;
            };
            if (!parent_found) scratch.parents.appendAssumeCapacity(.{ .id = surface.id, .stack = stack });
        }
    }

    for (scratch.plan.items) |token| self.clearOwnedClaims(self.updateForToken(token) orelse unreachable);
    if (self.presentation_listener) |listener| listener.applied(listener.context, .{
        .surfaces = scratch.surfaces.items,
        .parents = scratch.parents.items,
    });

    for (self.clients.items) |objects| for (objects.surfaces.items) |surface| {
        while (surface.content_updates.items.len != 0 and
            tokenIn(scratch.plan.items, surface.content_updates.items[0].token))
        {
            var update = surface.content_updates.orderedRemove(0);
            update.deinit(self.allocator);
        }
    };
}

fn clearOwnedClaims(self: *WayringCompositor, update: *ContentUpdate) void {
    for (update.claims.items) |claim| {
        const claimed = self.updateForToken(claim.token) orelse continue;
        if (claimed.claimed_by) |owner| {
            if (std.meta.eql(owner, update.token)) claimed.claimed_by = null;
        }
    }
}

fn unlinkIncomingClaim(self: *WayringCompositor, update: *ContentUpdate) void {
    const owner_token = update.claimed_by orelse return;
    update.claimed_by = null;
    const owner = self.updateForToken(owner_token) orelse return;
    for (owner.claims.items, 0..) |claim, index| {
        if (!std.meta.eql(claim.token, update.token)) continue;
        _ = owner.claims.orderedRemove(index);
        return;
    }
}

fn discardUpdateAt(self: *WayringCompositor, surface: *Surface, index: usize) void {
    const token = surface.content_updates.items[index].token;
    self.unlinkIncomingClaim(&surface.content_updates.items[index]);
    self.clearOwnedClaims(&surface.content_updates.items[index]);
    var callback_index: usize = 0;
    while (callback_index < surface.frame_callbacks.items.len) {
        const discard = switch (surface.frame_callbacks.items[callback_index].state) {
            .queued => |queued| std.meta.eql(queued, token),
            .pending, .committed => false,
        };
        if (discard) {
            destroyFrameCallback(self, surface, callback_index);
        } else {
            callback_index += 1;
        }
    }
    var update = surface.content_updates.orderedRemove(index);
    update.deinit(self.allocator);
}

fn discardSurfaceQueue(self: *WayringCompositor, surface: *Surface) void {
    while (surface.content_updates.items.len != 0) self.discardUpdateAt(surface, 0);
}

fn prepareCommit(self: *WayringCompositor, surface: *Surface) !PreparedCommit {
    var prepared = PreparedCommit.init(surface);
    errdefer prepared.deinit();
    prepared.physical_size = self.projectedPhysicalSize(surface);

    if (self.failCommitAt(.candidate_allocation)) return error.OutOfMemory;
    try prepared.damage.copyFrom(&surface.pending_damage);
    if (self.failCommitAt(.prepared_owned)) return error.OutOfMemory;
    if (surface.pending_opaque_dirty) {
        var opaque_region = Region.init();
        var opaque_region_owned = true;
        errdefer if (opaque_region_owned) opaque_region.deinit();
        try opaque_region.copyFrom(&surface.pending_opaque);
        prepared.opaque_region = opaque_region;
        opaque_region_owned = false;
    }
    if (self.failCommitAt(.region_copy)) return error.OutOfMemory;
    if (surface.pending_input_dirty) {
        var input = InputRegion.init();
        var input_owned = true;
        errdefer if (input_owned) input.deinit();
        try input.copyFrom(&surface.pending_input);
        prepared.input = input;
        input_owned = false;
    }

    if (surface.has_pending_attachment) {
        if (surface.pending_attachment) |*pending| {
            try self.preparePendingBuffer(surface, pending, &prepared);
        } else {
            prepared.physical_size = null;
            prepared.logical_size = null;
        }
    } else if (prepared.physical_size) |physical_size| {
        prepared.logical_size = try logicalSize(physical_size, prepared.scale, prepared.transform);
    } else {
        prepared.logical_size = null;
    }
    return prepared;
}

fn preparePendingBuffer(
    self: *WayringCompositor,
    surface: *Surface,
    pending: *PendingAttachment,
    prepared: *PreparedCommit,
) !void {
    if (self.failCommitAt(.access)) return error.InvalidBacking;
    var access = pending.pin.access() catch |err| {
        return err;
    };
    var access_live = true;
    defer if (access_live) access.end() catch {};
    const geometry = access.geometry;
    const physical_size: render.Size = .{
        .width = @intCast(geometry.width),
        .height = @intCast(geometry.height),
    };
    prepared.physical_size = physical_size;
    prepared.logical_size = try logicalSize(physical_size, prepared.scale, prepared.transform);
    const source_cache: render.SourceCache = .{
        .id = surface.source_cache_id,
        .version = surface.next_source_version,
    };
    if (self.failCommitAt(.copy)) return error.OutOfMemory;
    prepared.buffer = try CopiedBufferSnapshot.copy(
        self.allocator,
        .{
            .bytes = access.bytes,
            .size = physical_size,
            .stride_bytes = geometry.stride,
            .format = switch (geometry.format) {
                .argb8888 => .argb8888,
                .xrgb8888 => .xrgb8888,
            },
        },
        null,
        null,
        source_cache,
    );
    prepared.publishes_snapshot = true;
    if (self.failCommitAt(.access_end)) {
        access.end() catch {};
        access_live = false;
        return error.InvalidBacking;
    }
    access.end() catch |err| {
        access_live = false;
        return err;
    };
    access_live = false;
}

fn logicalSize(
    physical_size: render.Size,
    scale: i32,
    transform: render.BufferTransform,
) error{InvalidSize}!render.Size {
    if (scale <= 0) return error.InvalidSize;
    const transformed = transform.applyToSize(physical_size);
    const divisor: u32 = @intCast(scale);
    if (transformed.width % divisor != 0 or transformed.height % divisor != 0)
        return error.InvalidSize;
    return .{
        .width = transformed.width / divisor,
        .height = transformed.height / divisor,
    };
}

fn publishPreparedCommit(
    self: *WayringCompositor,
    surface: *Surface,
    prepared: *PreparedCommit,
    token: UpdateToken,
    notify_listener: bool,
) void {
    // Wayland 1.26 applies the buffer before every other CU field so all
    // coordinates and regions are interpreted against the new content.
    if (prepared.attachment_changed) std.mem.swap(?CopiedBufferSnapshot, &surface.current, &prepared.buffer);
    if (prepared.opaque_region) |*opaque_region| std.mem.swap(Region, &surface.current_opaque, opaque_region);
    if (prepared.input) |*input| std.mem.swap(InputRegion, &surface.current_input, input);
    surface.current_logical_size = prepared.logical_size;
    surface.current_scale = prepared.scale;
    surface.current_transform = prepared.transform;
    surface.current_offset_x = prepared.offset_x;
    surface.current_offset_y = prepared.offset_y;

    // Offset is applied protocol metadata for this content update. Phase 2's
    // roleless root policy intentionally keeps rendering at the global origin;
    // future roles can consume the exact applied value without leaking it into
    // SurfaceRegistry or Scene prematurely.
    var callbacks_to_commit = prepared.pending_frame_callback_count;
    for (surface.frame_callbacks.items) |callback| switch (callback.state) {
        .queued => |queued| if (std.meta.eql(queued, token)) {
            callback.state = .committed;
            callbacks_to_commit -= 1;
        },
        .pending, .committed => {},
    };
    std.debug.assert(callbacks_to_commit == 0);

    std.debug.assert((surface.current != null) == (surface.current_logical_size != null));
    if (notify_listener) if (self.presentation_listener) |listener| {
        const surfaces = [_]AppliedSurfaceState{.{
            .id = surface.id,
            .mapped_size = surface.current_logical_size,
            .callbacks_committed = prepared.pending_frame_callback_count != 0,
        }};
        listener.applied(listener.context, .{ .surfaces = &surfaces, .parents = &.{} });
    };
}

fn failCommitAt(self: *WayringCompositor, point: CommitFault) bool {
    if (comptime !builtin.is_test) return false;
    if (self.commit_fault != point) return false;
    self.commit_fault = null;
    return true;
}

fn clearPendingAttachment(surface: *Surface) void {
    if (surface.pending_attachment) |*pending| {
        pending.deinit();
        surface.pending_attachment = null;
    }
    surface.has_pending_attachment = false;
}

fn clearPendingOffset(surface: *Surface) void {
    surface.pending_offset_x = 0;
    surface.pending_offset_y = 0;
}

fn pendingFrameCallbackCount(surface: *const Surface) usize {
    var count: usize = 0;
    var saw_pending = false;
    for (surface.frame_callbacks.items) |callback| switch (callback.state) {
        .committed, .queued => std.debug.assert(!saw_pending),
        .pending => {
            saw_pending = true;
            count += 1;
        },
    };
    return count;
}

fn clientObjects(self: *WayringCompositor, client: *server.Client) !*ClientObjects {
    if (self.findClient(client)) |objects| return objects;
    const objects = try self.allocator.create(ClientObjects);
    errdefer self.allocator.destroy(objects);
    objects.* = .{ .client = client };
    try self.clients.append(self.allocator, objects);
    return objects;
}

fn findClient(self: *WayringCompositor, client: *const server.Client) ?*ClientObjects {
    for (self.clients.items) |objects| if (objects.client == client) return objects;
    return null;
}

fn surfaceForId(self: *const WayringCompositor, id: SurfaceId) ?*Surface {
    for (self.clients.items) |objects| {
        for (objects.surfaces.items) |surface| {
            if (std.meta.eql(surface.id, id)) return surface;
        }
    }
    return null;
}

fn clientForResource(self: *WayringCompositor, resource: *server.Resource) ?*server.Client {
    for (self.clients.items) |objects| {
        if (resource.ownedBy(objects.client.ownerHooks())) return objects.client;
    }
    return null;
}

fn destroySubcompositor(self: *WayringCompositor, value: *Subcompositor) void {
    const client = self.clientForResource(&value.resource.runtime) orelse unreachable;
    const objects = self.findClient(client) orelse unreachable;
    removePointer(Subcompositor, &objects.subcompositors, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn notifyDetached(self: *WayringCompositor, child: *Surface, identity: AssociationIdentity) void {
    const relationship = self.exactRelationship(child, identity) orelse return;
    if (relationship.detached) return;
    relationship.detached = true;
    if (self.presentation_listener) |listener| listener.detached(listener.context, child.id);
}

/// Removes one exact association without touching a replacement that happens
/// to reuse the same canonical child. Queued CUs hold only this identity, so a
/// stale topology snapshot can never retain or recover the role resource.
fn dissociate(self: *WayringCompositor, child: *Surface, identity: AssociationIdentity) bool {
    _ = self.exactRelationship(child, identity) orelse return false;
    self.discardSurfaceQueue(child);
    if (self.surfaceForId(identity.parent)) |parent| {
        for (parent.children.items, 0..) |entry, index| {
            if (!std.meta.eql(entry.identity, identity)) continue;
            _ = parent.children.orderedRemove(index);
            if (index < parent.parent_sentinel_index) parent.parent_sentinel_index -= 1;
            parent.topology_dirty = true;
            break;
        }
    }
    self.notifyDetached(child, identity);
    child.relationship = null;
    return true;
}

fn destroySubsurface(self: *WayringCompositor, value: *Subsurface) void {
    const client = self.clientForResource(&value.resource.runtime) orelse unreachable;
    const objects = self.findClient(client) orelse unreachable;
    if (self.surfaceForId(value.identity.child)) |child| {
        if (child.active_subsurface == value and self.exactRelationship(child, value.identity) != null) {
            _ = self.dissociate(child, value.identity);
            child.active_subsurface = null;
        }
    }
    removePointer(Subsurface, &objects.subsurfaces, value);
    value.resource.destroy();
    value.resource.deinit();
    self.allocator.destroy(value);
}

fn destroySurface(self: *WayringCompositor, surface: *Surface) void {
    const client = self.clientForResource(&surface.resource.runtime) orelse unreachable;
    const objects = self.findClient(client) orelse unreachable;
    std.debug.assert(!surface.destroying);
    surface.destroying = true;
    self.discardSurfaceQueue(surface);
    if (surface.relationship) |relationship| if (self.surfaceForId(relationship.identity.parent)) |parent| {
        for (parent.children.items, 0..) |entry, index| if (std.meta.eql(entry.identity, relationship.identity)) {
            _ = parent.children.orderedRemove(index);
            if (index < parent.parent_sentinel_index) parent.parent_sentinel_index -= 1;
            parent.topology_dirty = true;
            break;
        };
    };
    for (surface.children.items) |entry| {
        if (self.surfaceForId(entry.identity.child)) |child| {
            if (child.relationship) |relationship| {
                if (std.meta.eql(relationship.identity, entry.identity)) self.notifyDetached(child, entry.identity);
            }
        }
    }
    surface.children.deinit(self.allocator);
    if (self.presentation_listener) |listener|
        listener.removing(listener.context, surface.id);
    self.surface_registry.remove(surface.id);
    std.debug.assert(self.owned_provider_count > 0);
    self.owned_provider_count -= 1;
    removePointer(Surface, &objects.surfaces, surface);
    while (surface.frame_callbacks.items.len > 0)
        destroyFrameCallback(self, surface, 0);
    surface.frame_callbacks.deinit(self.allocator);
    surface.content_updates.deinit(self.allocator);
    clearPendingAttachment(surface);
    if (surface.current) |*current| current.deinit();
    surface.current_input.deinit();
    surface.pending_input.deinit();
    surface.current_opaque.deinit();
    surface.pending_opaque.deinit();
    surface.pending_damage.deinit();
    surface.resource.destroy();
    surface.resource.deinit();
    self.allocator.destroy(surface);
}

fn destroyFrameCallback(self: *WayringCompositor, surface: *Surface, index: usize) void {
    const callback = surface.frame_callbacks.orderedRemove(index);
    callback.resource.destroy();
    callback.resource.deinit();
    self.allocator.destroy(callback);
}

fn destroyRegion(self: *WayringCompositor, region: *RegionResource) void {
    const client = self.clientForResource(&region.resource.runtime) orelse unreachable;
    const objects = self.findClient(client) orelse unreachable;
    removePointer(RegionResource, &objects.regions, region);
    region.resource.destroy();
    region.resource.deinit();
    region.value.deinit();
    self.allocator.destroy(region);
}

fn destroyCompositor(self: *WayringCompositor, compositor: *Compositor) void {
    const client = self.clientForResource(&compositor.resource.runtime) orelse unreachable;
    const objects = self.findClient(client) orelse unreachable;
    removePointer(Compositor, &objects.compositors, compositor);
    compositor.resource.destroy();
    compositor.resource.deinit();
    self.allocator.destroy(compositor);
}

fn removePointer(comptime T: type, items: *std.ArrayList(*T), value: *T) void {
    for (items.items, 0..) |candidate, index| {
        if (candidate != value) continue;
        _ = items.orderedRemove(index);
        return;
    }
    unreachable;
}

fn encode(object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) ![]u8 {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    const bytes = try std.testing.allocator.dupe(u8, batch.bytes);
    try output.completeSend(batch.token, batch.bytes.len);
    return bytes;
}

fn send(client: *server.Client, object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
    const bytes = try encode(object_id, opcode, descriptor, values);
    defer std.testing.allocator.free(bytes);
    try client.receive(bytes, &.{});
    try client.dispatch();
}

fn sendWithFds(client: *server.Client, object_id: u32, opcode: u16, descriptor: *const wire.MessageDescriptor, values: []const wire.Value) !void {
    var output: wire.Output = .init(std.testing.allocator);
    defer output.deinit();
    try output.enqueue(object_id, opcode, descriptor, values);
    const batch = (try output.beginSend()).?;
    var receiver_fds: std.ArrayList(wire.FileDescriptor) = .empty;
    defer receiver_fds.deinit(std.testing.allocator);
    try receiver_fds.ensureUnusedCapacity(std.testing.allocator, batch.fds.len);
    errdefer {
        for (receiver_fds.items) |fd| _ = std.c.close(fd);
    }
    for (batch.fds) |fd| {
        const duplicate = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (duplicate < 0) return error.Unexpected;
        receiver_fds.appendAssumeCapacity(duplicate);
    }
    try client.receive(batch.bytes, receiver_fds.items);
    receiver_fds.clearRetainingCapacity();
    try output.completeSend(batch.token, batch.bytes.len);
    try client.dispatch();
}

fn memfdWithPixels(pixels: []const u32) !std.posix.fd_t {
    const bytes = std.mem.sliceAsBytes(pixels);
    const fd = try std.posix.memfd_create("keywork-wayring-surface", std.os.linux.MFD.CLOEXEC);
    errdefer _ = std.c.close(fd);
    if (std.os.linux.errno(std.os.linux.ftruncate(fd, @intCast(bytes.len))) != .SUCCESS) return error.Unexpected;
    const written = std.c.write(fd, bytes.ptr, bytes.len);
    if (written != bytes.len) return error.Unexpected;
    return fd;
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
    return std.mem.readInt(u32, bytes[offset..][0..4], .native);
}

fn expectCallbackDoneAndDelete(
    bytes: []const u8,
    offset: usize,
    callback_id: u32,
    timestamp_ms: u32,
) !void {
    try std.testing.expect(offset + 24 <= bytes.len);
    try std.testing.expectEqual(callback_id, word(bytes, offset));
    try std.testing.expectEqual(@as(u16, 0), @as(u16, @truncate(word(bytes, offset + 4))));
    try std.testing.expectEqual(@as(u16, 12), @as(u16, @truncate(word(bytes, offset + 4) >> 16)));
    try std.testing.expectEqual(timestamp_ms, word(bytes, offset + 8));
    try std.testing.expectEqual(@as(u32, 1), word(bytes, offset + 12));
    try std.testing.expectEqual(@as(u16, 1), @as(u16, @truncate(word(bytes, offset + 16))));
    try std.testing.expectEqual(@as(u16, 12), @as(u16, @truncate(word(bytes, offset + 16) >> 16)));
    try std.testing.expectEqual(callback_id, word(bytes, offset + 20));
}

fn expectDeleteIds(bytes: []const u8, ids: []const u32) !void {
    try std.testing.expectEqual(ids.len * 12, bytes.len);
    for (ids, 0..) |id, index| {
        const offset = index * 12;
        try std.testing.expectEqual(@as(u32, 1), word(bytes, offset));
        try std.testing.expectEqual(@as(u16, 1), @as(u16, @truncate(word(bytes, offset + 4))));
        try std.testing.expectEqual(@as(u16, 12), @as(u16, @truncate(word(bytes, offset + 4) >> 16)));
        try std.testing.expectEqual(id, word(bytes, offset + 8));
    }
}

fn expectInitialSurfacePreferences(bytes: []const u8, surface_id: u32) !void {
    try std.testing.expectEqual(@as(usize, 24), bytes.len);
    try std.testing.expectEqual(surface_id, word(bytes, 0));
    try std.testing.expectEqual(
        @as(u16, preferred_buffer_scale_event_opcode),
        @as(u16, @truncate(word(bytes, 4))),
    );
    try std.testing.expectEqual(@as(u16, 12), @as(u16, @truncate(word(bytes, 4) >> 16)));
    try std.testing.expectEqual(@as(u32, 1), word(bytes, 8));
    try std.testing.expectEqual(surface_id, word(bytes, 12));
    try std.testing.expectEqual(
        @as(u16, preferred_buffer_transform_event_opcode),
        @as(u16, @truncate(word(bytes, 16))),
    );
    try std.testing.expectEqual(@as(u16, 12), @as(u16, @truncate(word(bytes, 16) >> 16)));
    try std.testing.expectEqual(@as(u32, @intCast(core.wl_output.transform.normal)), word(bytes, 20));
}

fn bindCompositor(client: *server.Client, compositor_id: u32) !void {
    try bindCompositorVersion(client, compositor_id, 1);
}

fn bindCompositorVersion(client: *server.Client, compositor_id: u32, version: u32) !void {
    try send(client, 1, 1, &core.wl_display.request_messages[1], &.{.{ .new_id = .{ .typed = 2 } }});
    const globals = try drain(client);
    defer std.testing.allocator.free(globals);
    const global_name = word(globals, 8);
    try send(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = global_name },
        .{ .new_id = .{ .generic = .{ .interface = "wl_compositor", .version = version, .id = compositor_id } } },
    });
}

fn bindShm(self: *WayringCompositor, client: *server.Client, shm_id: u32) !void {
    try send(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = self.shm.global.?.name() },
        .{ .new_id = .{ .generic = .{ .interface = "wl_shm", .version = 1, .id = shm_id } } },
    });
    const formats = try drain(client);
    defer std.testing.allocator.free(formats);
}

fn bindTestSubcompositor(self: *WayringCompositor, client: *server.Client, id: u32) !void {
    try send(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = self.subcompositor_global.name() },
        .{ .new_id = .{ .generic = .{ .interface = "wl_subcompositor", .version = 1, .id = id } } },
    });
}

fn getSubsurface(client: *server.Client, manager_id: u32, id: u32, child_id: u32, parent_id: u32) !void {
    try send(client, manager_id, 1, &core.wl_subcompositor.request_messages[1], &.{
        .{ .new_id = .{ .typed = id } }, .{ .object = child_id }, .{ .object = parent_id },
    });
}

fn setSubsurfacePosition(client: *server.Client, id: u32, x: i32, y: i32) !void {
    try send(client, id, 1, &core.wl_subsurface.request_messages[1], &.{ .{ .int = x }, .{ .int = y } });
}

fn placeSubsurface(client: *server.Client, id: u32, sibling_id: u32, above: bool) !void {
    const opcode: u16 = if (above) 2 else 3;
    try send(client, id, opcode, &core.wl_subsurface.request_messages[opcode], &.{.{ .object = sibling_id }});
}

fn setSubsurfaceMode(client: *server.Client, id: u32, sync: bool) !void {
    const opcode: u16 = if (sync) 4 else 5;
    try send(client, id, opcode, &core.wl_subsurface.request_messages[opcode], &.{});
}

fn destroySubsurfaceResource(client: *server.Client, id: u32) !void {
    try send(client, id, 0, &core.wl_subsurface.request_messages[0], &.{});
}

fn expectPendingChildren(parent: *const Surface, expected: []const SurfaceId, sentinel: usize) !void {
    try std.testing.expectEqual(expected.len, parent.children.items.len);
    try std.testing.expectEqual(sentinel, parent.parent_sentinel_index);
    for (expected, parent.children.items) |id, placement|
        try std.testing.expectEqual(id, placement.identity.child);
}

fn createSurfaceResource(client: *server.Client, compositor_id: u32, surface_id: u32) !void {
    try send(client, compositor_id, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = surface_id } }});
}

fn createRegionResource(client: *server.Client, compositor_id: u32, region_id: u32) !void {
    try send(client, compositor_id, 1, &core.wl_compositor.request_messages[1], &.{.{ .new_id = .{ .typed = region_id } }});
}

fn changeRegion(
    client: *server.Client,
    region_id: u32,
    opcode: u16,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) !void {
    try send(client, region_id, opcode, &core.wl_region.request_messages[opcode], &.{
        .{ .int = x },
        .{ .int = y },
        .{ .int = width },
        .{ .int = height },
    });
}

fn addRegion(client: *server.Client, region_id: u32, x: i32, y: i32, width: i32, height: i32) !void {
    try changeRegion(client, region_id, 1, x, y, width, height);
}

fn subtractRegion(client: *server.Client, region_id: u32, x: i32, y: i32, width: i32, height: i32) !void {
    try changeRegion(client, region_id, 2, x, y, width, height);
}

fn setSurfaceRegion(client: *server.Client, surface_id: u32, opcode: u16, region_id: ?u32) !void {
    try send(client, surface_id, opcode, &core.wl_surface.request_messages[opcode], &.{.{ .object = region_id }});
}

fn createShmPool(client: *server.Client, shm_id: u32, pool_id: u32, fd: std.posix.fd_t, size: usize) !void {
    try sendWithFds(client, shm_id, 0, &core.wl_shm.request_messages[0], &.{
        .{ .new_id = .{ .typed = pool_id } }, .{ .fd = fd }, .{ .int = @intCast(size) },
    });
}

fn createShmBuffer(
    client: *server.Client,
    pool_id: u32,
    buffer_id: u32,
    offset: usize,
    size: render.Size,
    stride_bytes: usize,
    format: server.shm.Format,
) !void {
    try send(client, pool_id, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = buffer_id } },
        .{ .int = @intCast(offset) },
        .{ .int = @intCast(size.width) },
        .{ .int = @intCast(size.height) },
        .{ .int = @intCast(stride_bytes) },
        .{ .uint = @intFromEnum(format) },
    });
}

fn attachBuffer(client: *server.Client, surface_id: u32, buffer_id: ?u32) !void {
    try attachBufferAt(client, surface_id, buffer_id, 0, 0);
}

fn attachBufferAt(client: *server.Client, surface_id: u32, buffer_id: ?u32, x: i32, y: i32) !void {
    try send(client, surface_id, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = buffer_id }, .{ .int = x }, .{ .int = y },
    });
}

fn damageSurface(client: *server.Client, surface_id: u32, rectangle: render.Rect) !void {
    try send(client, surface_id, 2, &core.wl_surface.request_messages[2], &.{
        .{ .int = rectangle.x },
        .{ .int = rectangle.y },
        .{ .int = @intCast(rectangle.width) },
        .{ .int = @intCast(rectangle.height) },
    });
}

fn damageBuffer(
    client: *server.Client,
    surface_id: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) !void {
    try send(client, surface_id, 9, &core.wl_surface.request_messages[9], &.{
        .{ .int = x },
        .{ .int = y },
        .{ .int = width },
        .{ .int = height },
    });
}

fn setSurfaceOffset(client: *server.Client, surface_id: u32, x: i32, y: i32) !void {
    try send(client, surface_id, 10, &core.wl_surface.request_messages[10], &.{
        .{ .int = x },
        .{ .int = y },
    });
}

fn commitSurfaceResource(client: *server.Client, surface_id: u32) !void {
    try send(client, surface_id, 6, &core.wl_surface.request_messages[6], &.{});
}

fn setBufferTransform(client: *server.Client, surface_id: u32, transform: i32) !void {
    try send(client, surface_id, 7, &core.wl_surface.request_messages[7], &.{.{ .int = transform }});
}

fn setBufferScale(client: *server.Client, surface_id: u32, scale: i32) !void {
    try send(client, surface_id, 8, &core.wl_surface.request_messages[8], &.{.{ .int = scale }});
}

fn requestFrame(client: *server.Client, surface_id: u32, callback_id: u32) !void {
    try send(client, surface_id, 3, &core.wl_surface.request_messages[3], &.{
        .{ .new_id = .{ .typed = callback_id } },
    });
}

// Scanner tests construct exact negotiated versions beyond the production
// global without changing child version inheritance.
fn replaceCompositorResourceForTest(
    self: *WayringCompositor,
    client: *server.Client,
    compositor: *Compositor,
    version: u32,
) !void {
    const objects = self.findClient(client).?;
    std.debug.assert(objects.surfaces.items.len == 0);
    std.debug.assert(objects.regions.items.len == 0);
    const object_id = compositor.resource.id();
    compositor.resource.destroy();
    compositor.resource.deinit();
    const delete_id = try drain(client);
    defer std.testing.allocator.free(delete_id);
    try std.testing.expectEqual(@as(usize, 12), delete_id.len);
    try std.testing.expectEqual(object_id, word(delete_id, 8));

    compositor.resource = .init(self.allocator, object_id, version, .client, client.ownerHooks());
    try compositor.resource.setHandler(WayringCompositor, self, handleCompositor, null);
    try client.installClientInitial(object_id, &compositor.resource.runtime);
}

fn replaceSurfaceResourceForTest(
    self: *WayringCompositor,
    client: *server.Client,
    surface: *Surface,
    version: u32,
) !void {
    std.debug.assert(surface.pending_attachment == null);
    std.debug.assert(!surface.has_pending_attachment);
    std.debug.assert(surface.current == null);
    const object_id = surface.resource.id();
    surface.resource.destroy();
    surface.resource.deinit();
    const delete_id = try drain(client);
    defer std.testing.allocator.free(delete_id);
    try std.testing.expectEqual(@as(usize, 12), delete_id.len);
    try std.testing.expectEqual(@as(u32, object_id), word(delete_id, 8));

    surface.resource = .init(self.allocator, object_id, version, .client, client.ownerHooks());
    try surface.resource.setHandler(WayringCompositor, self, handleSurface, null);
    try client.installClientInitial(object_id, &surface.resource.runtime);
}

const SyntheticRegistryProvider = struct {
    pixel: u32,

    fn provider(self: *SyntheticRegistryProvider) SurfaceRegistry.Provider {
        return .{ .context = self, .render_state = renderState };
    }

    fn renderState(context: *anyopaque) ?SurfaceRegistry.RenderState {
        const self: *SyntheticRegistryProvider = @ptrCast(@alignCast(context));
        return .{
            .buffer = .{
                .size = .{ .width = 1, .height = 1 },
                .stride_pixels = 1,
                .pixels = @as([*]u32, @ptrCast(&self.pixel))[0..1],
            },
            .logical_size = .{ .width = 1, .height = 1 },
        };
    }
};

const TestPresentationListener = struct {
    const Event = enum { added, committed, removing };

    registry: *SurfaceRegistry,
    compositor: ?*WayringCompositor = null,
    fail_added: bool = false,
    require_owned_lookup_on_remove: bool = true,
    events: [16]Event = undefined,
    event_count: usize = 0,
    added_count: usize = 0,
    detached_count: usize = 0,
    committed_count: usize = 0,
    removing_count: usize = 0,
    last_id: ?SurfaceId = null,
    last_size: ?render.Size = null,
    last_source_cache: ?render.SourceCache = null,
    last_pixel_pointer: ?[*]u32 = null,
    last_first_pixel: ?u32 = null,
    frame_completion: ?FrameCompletion = null,
    last_callbacks_committed: bool = false,
    callbacks_committed_count: usize = 0,
    removing_had_render_state: bool = false,
    last_batch_surface_count: usize = 0,
    last_batch_parent_count: usize = 0,
    last_batch_surface_ids: [32]SurfaceId = undefined,
    last_batch_callbacks: [32]bool = undefined,
    last_batch_parent_ids: [16]SurfaceId = undefined,
    last_parent_stack_lengths: [16]usize = undefined,
    last_stack_child_ids: [32]SurfaceId = undefined,
    last_stack_child_positions: [32]Position = undefined,
    last_stack_child_count: usize = 0,

    fn listener(self: *TestPresentationListener) PresentationListener {
        return .{
            .context = self,
            .added = added,
            .detached = detached,
            .applied = applied,
            .removing = removing,
        };
    }

    fn added(
        context: *anyopaque,
        id: SurfaceId,
        frame_completion: FrameCompletion,
    ) error{OutOfMemory}!void {
        const self: *TestPresentationListener = @ptrCast(@alignCast(context));
        std.debug.assert(self.registry.contains(id));
        std.debug.assert(self.registry.renderState(id) == null);
        self.record(.added);
        self.added_count += 1;
        self.last_id = id;
        self.frame_completion = frame_completion;
        if (self.fail_added) return error.OutOfMemory;
    }

    fn detached(context: *anyopaque, id: SurfaceId) void {
        const self: *TestPresentationListener = @ptrCast(@alignCast(context));
        std.debug.assert(self.registry.contains(id));
        self.detached_count += 1;
    }

    fn applied(context: *anyopaque, batch: AppliedBatch) void {
        const self: *TestPresentationListener = @ptrCast(@alignCast(context));
        std.debug.assert(batch.surfaces.len <= self.last_batch_surface_ids.len);
        std.debug.assert(batch.parents.len <= self.last_batch_parent_ids.len);
        self.last_batch_surface_count = batch.surfaces.len;
        self.last_batch_parent_count = batch.parents.len;
        self.last_stack_child_count = 0;
        for (batch.surfaces, 0..) |applied_surface, index| {
            const id = applied_surface.id;
            self.last_batch_surface_ids[index] = id;
            self.last_batch_callbacks[index] = applied_surface.callbacks_committed;
            const size = applied_surface.mapped_size;
            const callbacks_committed = applied_surface.callbacks_committed;
            std.debug.assert(self.registry.contains(id));
            const state = self.registry.renderState(id);
            if (size) |mapped_size| {
                std.debug.assert(state != null);
                std.debug.assert(std.meta.eql(mapped_size, state.?.logical_size));
                self.last_source_cache = state.?.buffer.source_cache;
                self.last_pixel_pointer = state.?.buffer.pixels.ptr;
                self.last_first_pixel = state.?.buffer.pixels[0];
            } else {
                std.debug.assert(state == null);
                self.last_source_cache = null;
                self.last_pixel_pointer = null;
                self.last_first_pixel = null;
            }
            self.last_id = id;
            self.last_size = size;
            self.last_callbacks_committed = callbacks_committed;
            if (callbacks_committed) self.callbacks_committed_count += 1;
        }
        for (batch.parents, 0..) |parent, parent_index| {
            self.last_batch_parent_ids[parent_index] = parent.id;
            self.last_parent_stack_lengths[parent_index] = parent.stack.len;
            var sentinel_count: usize = 0;
            for (parent.stack) |entry| switch (entry) {
                .parent => sentinel_count += 1,
                .child => |child| {
                    std.debug.assert(self.last_stack_child_count < self.last_stack_child_ids.len);
                    self.last_stack_child_ids[self.last_stack_child_count] = child.id;
                    self.last_stack_child_positions[self.last_stack_child_count] = child.position;
                    self.last_stack_child_count += 1;
                },
            };
            std.debug.assert(sentinel_count == 1);
        }
        self.record(.committed);
        self.committed_count += 1;
    }

    fn removing(context: *anyopaque, id: SurfaceId) void {
        const self: *TestPresentationListener = @ptrCast(@alignCast(context));
        std.debug.assert(self.registry.contains(id));
        self.removing_had_render_state = self.registry.renderState(id) != null;
        if (self.require_owned_lookup_on_remove) {
            const compositor = self.compositor.?;
            std.debug.assert(compositor.containsSurface(id));
            std.debug.assert((compositor.currentBuffer(id) != null) == self.removing_had_render_state);
        }
        self.record(.removing);
        self.removing_count += 1;
        self.last_id = id;
    }

    fn record(self: *TestPresentationListener, event: Event) void {
        std.debug.assert(self.event_count < self.events.len);
        self.events[self.event_count] = event;
        self.event_count += 1;
    }
};

test "generated preferred buffer event descriptors preserve core wire metadata" {
    const scale = core.wl_surface.event_messages[preferred_buffer_scale_event_opcode];
    try std.testing.expectEqualStrings("preferred_buffer_scale", scale.name);
    try std.testing.expectEqual(@as(u32, 6), scale.since);
    try std.testing.expect(!scale.destructor);
    try std.testing.expectEqual(@as(usize, 1), scale.arguments.len);
    try std.testing.expectEqualStrings("factor", scale.arguments[0].name);
    try std.testing.expectEqual(.int, std.meta.activeTag(scale.arguments[0].kind));

    const transform = core.wl_surface.event_messages[preferred_buffer_transform_event_opcode];
    try std.testing.expectEqualStrings("preferred_buffer_transform", transform.name);
    try std.testing.expectEqual(@as(u32, 6), transform.since);
    try std.testing.expect(!transform.destructor);
    try std.testing.expectEqual(@as(usize, 1), transform.arguments.len);
    try std.testing.expectEqualStrings("transform", transform.arguments[0].name);
    try std.testing.expectEqual(.uint, std.meta.activeTag(transform.arguments[0].kind));
}

test "production wl_compositor advertises exactly v6 and bound children inherit v6" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, null);
    defer compositor.deinit();
    try std.testing.expectEqual(@as(u32, 6), compositor.global.version());
    try std.testing.expectEqualStrings("wl_compositor", compositor.global.interface().name);

    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }
    try bindCompositorVersion(client, 3, 6);
    try createSurfaceResource(client, 3, 4);
    try createRegionResource(client, 3, 5);

    const objects = compositor.findClient(client).?;
    try std.testing.expectEqual(@as(u32, 6), objects.compositors.items[0].resource.version());
    try std.testing.expectEqual(@as(u32, 6), objects.surfaces.items[0].resource.version());
    try std.testing.expectEqual(@as(u32, 6), objects.regions.items[0].resource.version());
    const preferences = try drain(client);
    defer std.testing.allocator.free(preferences);
    try expectInitialSurfacePreferences(preferences, 4);
    try std.testing.expect(client.fatal() == null);
}

test "only v6 surfaces receive one ordered fixed preference pair" {
    const Case = struct {
        fn run(version: u32) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var surface_registry = SurfaceRegistry.init(std.testing.allocator);
            defer surface_registry.deinit();
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &surface_registry, null);
            defer compositor.deinit();
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }

            try bindCompositorVersion(client, 3, version);
            try createSurfaceResource(client, 3, 4);
            try createRegionResource(client, 3, 5);
            const objects = compositor.findClient(client).?;
            try std.testing.expectEqual(version, objects.compositors.items[0].resource.version());
            try std.testing.expectEqual(version, objects.surfaces.items[0].resource.version());
            try std.testing.expectEqual(version, objects.regions.items[0].resource.version());

            const events = try drain(client);
            defer std.testing.allocator.free(events);
            if (version < compositor_version) {
                try std.testing.expectEqual(@as(usize, 0), events.len);
            } else {
                try expectInitialSurfacePreferences(events, 4);
            }
            try std.testing.expect(client.fatal() == null);
        }
    };

    for (1..compositor_version + 1) |version| try Case.run(@intCast(version));
}

test "initial preference enqueue failures preserve live new id until terminal cleanup" {
    const Outcome = enum { unrelated, scale_enqueue, transform_enqueue };
    const Case = struct {
        fn run(fail_offset: usize) !Outcome {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var surface_registry = SurfaceRegistry.init(std.testing.allocator);
            defer surface_registry.deinit();
            var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
            defer compositor.deinit();
            listener_state.compositor = &compositor;
            var client_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            const managed = try server.CoreClient.create(client_allocator.allocator(), &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }

            try bindCompositorVersion(client, 3, compositor_version);
            const create = try encode(
                3,
                0,
                &core.wl_compositor.request_messages[0],
                &.{.{ .new_id = .{ .typed = 4 } }},
            );
            defer std.testing.allocator.free(create);
            try client.receive(create, &.{});
            client_allocator.fail_index = client_allocator.alloc_index + fail_offset;
            try client.dispatch();

            const fatal = client.fatal() orelse return .unrelated;
            if (!std.mem.eql(u8, fatal.detail(), "queueing initial wl_surface preferences"))
                return .unrelated;
            try std.testing.expect(client_allocator.has_induced_failure);
            try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, fatal.kind);
            try std.testing.expectEqual(@as(usize, 1), compositor.surfaceCount());
            try std.testing.expectEqual(@as(usize, 1), surface_registry.len());
            try std.testing.expectEqual(@as(usize, 1), listener_state.added_count);
            try std.testing.expectEqual(@as(usize, 0), listener_state.removing_count);
            try std.testing.expect(client.lookup(4) != null);
            try std.testing.expect(compositor.surfaceId(client, 4) != null);

            const output = try drain(client);
            defer std.testing.allocator.free(output);
            const outcome: Outcome = if (word(output, 0) == 4) .transform_enqueue else .scale_enqueue;
            switch (outcome) {
                .scale_enqueue => try std.testing.expectEqual(@as(u32, 1), word(output, 0)),
                .transform_enqueue => {
                    try std.testing.expect(output.len > 12);
                    try std.testing.expectEqual(
                        @as(u16, preferred_buffer_scale_event_opcode),
                        @as(u16, @truncate(word(output, 4))),
                    );
                    try std.testing.expectEqual(@as(u16, 12), @as(u16, @truncate(word(output, 4) >> 16)));
                    try std.testing.expectEqual(@as(u32, 1), word(output, 8));
                    try std.testing.expectEqual(@as(u32, 1), word(output, 12));
                },
                .unrelated => unreachable,
            }

            compositor.destroyClientResources(client);
            try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());
            try std.testing.expectEqual(@as(usize, 0), surface_registry.len());
            try std.testing.expectEqual(@as(usize, 1), listener_state.removing_count);
            try std.testing.expect(client.lookup(4) == null);
            return outcome;
        }
    };

    var found_scale_failure = false;
    var found_transform_failure = false;
    for (0..32) |fail_offset| {
        switch (try Case.run(fail_offset)) {
            .unrelated => {},
            .scale_enqueue => found_scale_failure = true,
            .transform_enqueue => found_transform_failure = true,
        }
        if (found_scale_failure and found_transform_failure) break;
    }
    try std.testing.expect(found_scale_failure);
    try std.testing.expect(found_transform_failure);
}

test "v6 explicit and disconnect teardown emit no duplicate preferences" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositorVersion(client, 3, compositor_version);
    try createSurfaceResource(client, 3, 4);
    try createRegionResource(client, 3, 5);
    const preferences = try drain(client);
    defer std.testing.allocator.free(preferences);
    try expectInitialSurfacePreferences(preferences, 4);

    try send(client, 4, 0, &core.wl_surface.request_messages[0], &.{});
    const explicit_teardown = try drain(client);
    defer std.testing.allocator.free(explicit_teardown);
    try expectDeleteIds(explicit_teardown, &.{4});
    try std.testing.expectEqual(@as(usize, 1), listener_state.removing_count);
    try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());
    try std.testing.expectEqual(@as(usize, 1), compositor.regionCount());

    compositor.destroyClientResources(client);
    const disconnect_teardown = try drain(client);
    defer std.testing.allocator.free(disconnect_teardown);
    try expectDeleteIds(disconnect_teardown, &.{ 5, 3 });
    try std.testing.expectEqual(@as(usize, 1), listener_state.removing_count);
    try std.testing.expectEqual(@as(usize, 0), compositor.regionCount());
    try std.testing.expectEqual(@as(usize, 0), surface_registry.len());
}

test "v1 runtime since gate rejects set_buffer_transform before adapter mutation" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try createSurfaceResource(client, 3, 4);
    const surface = compositor.findClient(client).?.surfaces.items[0];
    try setBufferTransform(client, 4, @intCast(core.wl_output.transform.@"90"));

    const fatal = client.fatal().?;
    try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
    try std.testing.expectEqual(@as(u32, 4), fatal.object_id);
    try std.testing.expectEqual(@as(?u16, 7), fatal.opcode);
    try std.testing.expectEqualStrings("request unsupported by object version", fatal.detail());
    try std.testing.expectEqual(render.BufferTransform.normal, surface.pending_transform);
    try std.testing.expectEqual(render.BufferTransform.normal, surface.current_transform);
    try std.testing.expect(surface.current_logical_size == null);
    try std.testing.expectEqual(@as(usize, 0), listener_state.committed_count);
}

test "v1 and v2 runtime since gate reject set_buffer_scale before adapter mutation" {
    const Case = struct {
        fn run(version: u32) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var surface_registry = SurfaceRegistry.init(std.testing.allocator);
            defer surface_registry.deinit();
            var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
            defer compositor.deinit();
            listener_state.compositor = &compositor;
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }

            try bindCompositorVersion(client, 3, version);
            try createSurfaceResource(client, 3, 4);
            const surface = compositor.findClient(client).?.surfaces.items[0];
            try setBufferScale(client, 4, 2);

            const fatal = client.fatal().?;
            try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
            try std.testing.expectEqual(@as(u32, 4), fatal.object_id);
            try std.testing.expectEqual(@as(?u16, 8), fatal.opcode);
            try std.testing.expectEqualStrings("request unsupported by object version", fatal.detail());
            try std.testing.expectEqual(@as(i32, 1), surface.pending_scale);
            try std.testing.expectEqual(@as(i32, 1), surface.current_scale);
            try std.testing.expect(surface.current_logical_size == null);
            try std.testing.expectEqual(@as(usize, 0), listener_state.committed_count);
        }
    };

    try Case.run(1);
    try Case.run(2);
}

test "v1 through v3 runtime since gate reject damage_buffer before adapter handling" {
    const Case = struct {
        fn run(version: u32) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var surface_registry = SurfaceRegistry.init(std.testing.allocator);
            defer surface_registry.deinit();
            var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
            defer compositor.deinit();
            listener_state.compositor = &compositor;
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }

            try bindCompositorVersion(client, 3, version);
            try createSurfaceResource(client, 3, 4);
            const surface = compositor.findClient(client).?.surfaces.items[0];
            try damageBuffer(client, 4, std.math.minInt(i32), std.math.maxInt(i32), 1, 1);

            const fatal = client.fatal().?;
            try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
            try std.testing.expectEqual(@as(u32, 4), fatal.object_id);
            try std.testing.expectEqual(@as(?u16, 9), fatal.opcode);
            try std.testing.expectEqualStrings("request unsupported by object version", fatal.detail());
            try std.testing.expect(surface.pending_damage.isEmpty());
            try std.testing.expect(surface.current == null);
            try std.testing.expect(surface.current_logical_size == null);
            try std.testing.expectEqual(@as(usize, 0), listener_state.committed_count);
        }
    };

    try Case.run(1);
    try Case.run(2);
    try Case.run(3);
}

test "v1 through v4 runtime since gate reject offset before adapter mutation" {
    const descriptor = &core.wl_surface.request_messages[10];
    try std.testing.expectEqualStrings("offset", descriptor.name);
    try std.testing.expectEqual(@as(u32, 5), descriptor.since);
    try std.testing.expectEqual(@as(usize, 2), descriptor.arguments.len);
    try std.testing.expectEqualStrings("x", descriptor.arguments[0].name);
    try std.testing.expectEqualStrings("y", descriptor.arguments[1].name);
    try std.testing.expectEqual(wire.ArgumentKind.int, descriptor.arguments[0].kind);
    try std.testing.expectEqual(wire.ArgumentKind.int, descriptor.arguments[1].kind);

    const Case = struct {
        fn run(version: u32) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var surface_registry = SurfaceRegistry.init(std.testing.allocator);
            defer surface_registry.deinit();
            var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
            defer compositor.deinit();
            listener_state.compositor = &compositor;
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }

            try bindCompositorVersion(client, 3, version);
            try createSurfaceResource(client, 3, 4);
            const surface = compositor.findClient(client).?.surfaces.items[0];
            try setSurfaceOffset(client, 4, -17, 23);

            const fatal = client.fatal().?;
            try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
            try std.testing.expectEqual(@as(u32, 4), fatal.object_id);
            try std.testing.expectEqual(@as(?u16, 10), fatal.opcode);
            try std.testing.expectEqualStrings("request unsupported by object version", fatal.detail());
            try std.testing.expectEqual(@as(i32, 0), surface.pending_offset_x);
            try std.testing.expectEqual(@as(i32, 0), surface.pending_offset_y);
            try std.testing.expectEqual(@as(i32, 0), surface.current_offset_x);
            try std.testing.expectEqual(@as(i32, 0), surface.current_offset_y);
            try std.testing.expectEqual(@as(usize, 0), listener_state.committed_count);
        }
    };

    for (1..5) |version| try Case.run(@intCast(version));
}

test "v4 damage_buffer is allocation-free advisory state consumed at commit boundaries" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositorVersion(client, 3, 4);
    try bindShm(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    const id = compositor.surfaceId(client, 5).?;
    const surface = compositor.surfaceForId(id).?;
    const pixels = [_]u32{
        0xff11_0001, 0xff11_0002, 0xff11_0003, 0xff11_0004,
        0xff22_0001, 0xff22_0002, 0xff22_0003, 0xff22_0004,
    };
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
    try createShmBuffer(client, 6, 7, 0, .{ .width = 4, .height = 2 }, 4 * @sizeOf(u32), .argb8888);
    try setBufferScale(client, 5, 2);
    try setBufferTransform(client, 5, @intCast(core.wl_output.transform.@"90"));
    try attachBuffer(client, 5, 7);
    try commitSurfaceResource(client, 5);
    const release = try drain(client);
    defer std.testing.allocator.free(release);
    try std.testing.expectEqual(@as(usize, 8), release.len);

    const current_pointer = compositor.currentBuffer(id).?.pixels.ptr;
    const source_cache = surface_registry.renderState(id).?.buffer.source_cache.?;
    const source_version = surface.next_source_version;
    const committed_count = listener_state.committed_count;
    try requestFrame(client, 5, 8);
    const callback = surface.frame_callbacks.items[0];
    try std.testing.expectEqual(FrameCallback.State.pending, callback.state);
    const live_before_damage = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;

    try damageBuffer(client, 5, std.math.minInt(i32), std.math.maxInt(i32), std.math.maxInt(i32), 1);
    try damageBuffer(client, 5, std.math.maxInt(i32), std.math.minInt(i32), 0, std.math.maxInt(i32));
    try damageBuffer(client, 5, 0, 0, -1, 1);
    try damageBuffer(client, 5, 0, 0, 1, -1);

    try std.testing.expect(client.fatal() == null);
    try std.testing.expectEqual(
        live_before_damage,
        compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
    );
    try std.testing.expect(surface.pending_damage.isEmpty());
    try std.testing.expectEqual(current_pointer, compositor.currentBuffer(id).?.pixels.ptr);
    try std.testing.expectEqualSlices(u32, &pixels, compositor.currentBuffer(id).?.pixels);
    try std.testing.expectEqual(source_cache, surface_registry.renderState(id).?.buffer.source_cache.?);
    try std.testing.expectEqual(source_version, surface.next_source_version);
    try std.testing.expectEqual(@as(i32, 2), surface.current_scale);
    try std.testing.expectEqual(render.BufferTransform.rotate_90, surface.current_transform);
    try std.testing.expectEqual(render.Size{ .width = 1, .height = 2 }, surface.current_logical_size.?);
    try std.testing.expectEqual(committed_count, listener_state.committed_count);
    try std.testing.expectEqual(FrameCallback.State.pending, callback.state);

    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(committed_count + 1, listener_state.committed_count);
    try std.testing.expect(listener_state.last_callbacks_committed);
    try std.testing.expectEqual(FrameCallback.State.committed, callback.state);
    try std.testing.expectEqual(current_pointer, compositor.currentBuffer(id).?.pixels.ptr);
    try std.testing.expectEqual(source_cache, surface_registry.renderState(id).?.buffer.source_cache.?);
    try std.testing.expectEqual(source_version, surface.next_source_version);
    try std.testing.expectEqual(@as(i32, 2), surface.current_scale);
    try std.testing.expectEqual(render.BufferTransform.rotate_90, surface.current_transform);
    try std.testing.expectEqual(render.Size{ .width = 1, .height = 2 }, surface.current_logical_size.?);
    const no_release = try drain(client);
    defer std.testing.allocator.free(no_release);
    try std.testing.expectEqual(@as(usize, 0), no_release.len);

    const completion = listener_state.frame_completion.?;
    completion.complete(completion.context, id, 17);
    const callback_done = try drain(client);
    defer std.testing.allocator.free(callback_done);
    try expectCallbackDoneAndDelete(callback_done, 0, 8, 17);

    const mixed_committed_count = listener_state.committed_count;
    try damageSurface(client, 5, .{ .x = 0, .y = 1, .width = 1, .height = 1 });
    try damageBuffer(client, 5, -50, 60, 7, 8);
    try std.testing.expect(surface.pending_damage.contains(0, 1));
    try std.testing.expectEqual(mixed_committed_count, listener_state.committed_count);
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(mixed_committed_count + 1, listener_state.committed_count);
    try std.testing.expect(surface.pending_damage.isEmpty());
    try std.testing.expect(!listener_state.last_callbacks_committed);
    try std.testing.expectEqual(current_pointer, compositor.currentBuffer(id).?.pixels.ptr);
    try std.testing.expectEqual(source_cache, surface_registry.renderState(id).?.buffer.source_cache.?);
    try std.testing.expectEqual(source_version, surface.next_source_version);

    try requestFrame(client, 5, 9);
    try damageBuffer(client, 5, -1, -1, 2, 2);
    try attachBuffer(client, 5, null);
    const mapped_committed_count = listener_state.committed_count;
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(mapped_committed_count + 1, listener_state.committed_count);
    try std.testing.expect(listener_state.last_size == null);
    try std.testing.expect(listener_state.last_callbacks_committed);
    try std.testing.expect(compositor.currentBuffer(id) == null);
    try std.testing.expect(surface_registry.renderState(id) == null);
    try std.testing.expectEqual(source_version, surface.next_source_version);
    try std.testing.expectEqual(FrameCallback.State.committed, surface.frame_callbacks.items[0].state);
    try std.testing.expect(client.fatal() == null);
}

test "v2 unmapped transform commit publishes state without mapping content" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositorVersion(client, 3, 2);
    try createSurfaceResource(client, 3, 4);
    const id = compositor.surfaceId(client, 4).?;
    const surface = compositor.surfaceForId(id).?;
    try setBufferTransform(client, 4, @intCast(core.wl_output.transform.flipped_90));
    try std.testing.expectEqual(render.BufferTransform.flipped_90, surface.pending_transform);
    try std.testing.expectEqual(render.BufferTransform.normal, surface.current_transform);
    try std.testing.expect(surface_registry.renderState(id) == null);
    try std.testing.expectEqual(@as(usize, 0), listener_state.committed_count);

    try commitSurfaceResource(client, 4);
    try std.testing.expectEqual(render.BufferTransform.flipped_90, surface.current_transform);
    try std.testing.expect(surface.current_logical_size == null);
    try std.testing.expect(surface_registry.renderState(id) == null);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);
    try std.testing.expect(listener_state.last_size == null);
    try std.testing.expect(!listener_state.last_callbacks_committed);
    try std.testing.expect(client.fatal() == null);
}

test "v2 scanner maps every transform and commits attachment and state atomically" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositorVersion(client, 3, 2);
    try bindShm(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    const id = compositor.surfaceId(client, 5).?;
    const surface = compositor.surfaceForId(id).?;
    const pixels = [_]u32{
        0xff01_0101, 0xff02_0202, 0xff03_0303,
        0xff04_0404, 0xff05_0505, 0xff06_0606,
    };
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
    try createShmBuffer(
        client,
        6,
        7,
        0,
        .{ .width = 3, .height = 2 },
        3 * @sizeOf(u32),
        .argb8888,
    );

    try setBufferTransform(client, 5, @intCast(core.wl_output.transform.@"90"));
    try attachBuffer(client, 5, 7);
    try requestFrame(client, 5, 8);
    try std.testing.expectEqual(render.BufferTransform.rotate_90, surface.pending_transform);
    try std.testing.expectEqual(render.BufferTransform.normal, surface.current_transform);
    try std.testing.expect(surface_registry.renderState(id) == null);
    try commitSurfaceResource(client, 5);

    const current = compositor.currentBuffer(id).?;
    const current_pointer = current.pixels.ptr;
    const source_cache = surface_registry.renderState(id).?.buffer.source_cache.?;
    try std.testing.expectEqualSlices(u32, &pixels, current.pixels);
    try std.testing.expectEqual(render.BufferTransform.rotate_90, surface.current_transform);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 3 }, surface.current_logical_size.?);
    try std.testing.expectEqual(render.BufferTransform.rotate_90, surface_registry.renderState(id).?.transform);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 3 }, surface_registry.renderState(id).?.logical_size);
    try std.testing.expectEqual(FrameCallback.State.committed, surface.frame_callbacks.items[0].state);
    try std.testing.expect(listener_state.last_callbacks_committed);
    const release = try drain(client);
    defer std.testing.allocator.free(release);
    try std.testing.expectEqual(@as(usize, 8), release.len);
    try std.testing.expectEqual(@as(u32, 7), word(release, 0));
    const completion = listener_state.frame_completion.?;
    completion.complete(completion.context, id, 19);
    const callback_done = try drain(client);
    defer std.testing.allocator.free(callback_done);
    try expectCallbackDoneAndDelete(callback_done, 0, 8, 19);

    const Case = struct {
        protocol: i32,
        render_transform: render.BufferTransform,
        logical_size: render.Size,
    };
    const cases = [_]Case{
        .{ .protocol = @intCast(core.wl_output.transform.normal), .render_transform = .normal, .logical_size = .{ .width = 3, .height = 2 } },
        .{ .protocol = @intCast(core.wl_output.transform.@"90"), .render_transform = .rotate_90, .logical_size = .{ .width = 2, .height = 3 } },
        .{ .protocol = @intCast(core.wl_output.transform.@"180"), .render_transform = .rotate_180, .logical_size = .{ .width = 3, .height = 2 } },
        .{ .protocol = @intCast(core.wl_output.transform.@"270"), .render_transform = .rotate_270, .logical_size = .{ .width = 2, .height = 3 } },
        .{ .protocol = @intCast(core.wl_output.transform.flipped), .render_transform = .flipped, .logical_size = .{ .width = 3, .height = 2 } },
        .{ .protocol = @intCast(core.wl_output.transform.flipped_90), .render_transform = .flipped_90, .logical_size = .{ .width = 2, .height = 3 } },
        .{ .protocol = @intCast(core.wl_output.transform.flipped_180), .render_transform = .flipped_180, .logical_size = .{ .width = 3, .height = 2 } },
        .{ .protocol = @intCast(core.wl_output.transform.flipped_270), .render_transform = .flipped_270, .logical_size = .{ .width = 2, .height = 3 } },
    };
    for (cases, 0..) |case, index| {
        const old_transform = surface.current_transform;
        const old_size = surface.current_logical_size.?;
        const old_committed_count = listener_state.committed_count;
        try setBufferTransform(client, 5, case.protocol);
        try std.testing.expectEqual(case.render_transform, surface.pending_transform);
        try std.testing.expectEqual(old_transform, surface.current_transform);
        try std.testing.expectEqual(old_size, surface.current_logical_size.?);
        try std.testing.expectEqual(old_transform, surface_registry.renderState(id).?.transform);
        try std.testing.expectEqual(old_committed_count, listener_state.committed_count);

        try commitSurfaceResource(client, 5);
        try std.testing.expectEqual(case.render_transform, surface.current_transform);
        try std.testing.expectEqual(case.logical_size, surface.current_logical_size.?);
        const render_state = surface_registry.renderState(id).?;
        try std.testing.expectEqual(case.render_transform, render_state.transform);
        try std.testing.expectEqual(case.logical_size, render_state.logical_size);
        try std.testing.expectEqual(current_pointer, render_state.buffer.pixels.ptr);
        try std.testing.expectEqual(source_cache, render_state.buffer.source_cache.?);
        try std.testing.expectEqual(old_committed_count + 1, listener_state.committed_count);
        try std.testing.expectEqual(@as(usize, index + 2), listener_state.committed_count);
        try std.testing.expect(!listener_state.last_callbacks_committed);
        try std.testing.expectEqual(@as(u64, 2), surface.next_source_version);
    }

    try setBufferTransform(client, 5, @intCast(core.wl_output.transform.@"180"));
    try requestFrame(client, 5, 9);
    const committed_count = listener_state.committed_count;
    try setBufferTransform(client, 5, std.math.maxInt(i32));
    const fatal = client.fatal().?;
    try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
    try std.testing.expectEqual(@as(?u32, @intCast(core.wl_surface.@"error".invalid_transform)), fatal.protocol_code);
    try std.testing.expectEqual(@as(u32, 5), fatal.object_id);
    try std.testing.expectEqual(render.BufferTransform.rotate_180, surface.pending_transform);
    try std.testing.expectEqual(render.BufferTransform.flipped_270, surface.current_transform);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 3 }, surface.current_logical_size.?);
    try std.testing.expectEqual(render.BufferTransform.flipped_270, surface_registry.renderState(id).?.transform);
    try std.testing.expectEqual(current_pointer, surface_registry.renderState(id).?.buffer.pixels.ptr);
    try std.testing.expectEqual(committed_count, listener_state.committed_count);
    try std.testing.expectEqual(@as(usize, 1), surface.frame_callbacks.items.len);
    try std.testing.expectEqual(FrameCallback.State.pending, surface.frame_callbacks.items[0].state);
}

test "v3 scale composes with every transform without recopying retained content" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositorVersion(client, 3, 3);
    try bindShm(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    const id = compositor.surfaceId(client, 5).?;
    const surface = compositor.surfaceForId(id).?;
    var pixels: [12 * 8]u32 = undefined;
    for (&pixels, 0..) |*pixel, index| pixel.* = 0xff00_0000 | @as(u32, @intCast(index));
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
    try createShmBuffer(client, 6, 7, 0, .{ .width = 12, .height = 8 }, 12 * @sizeOf(u32), .argb8888);

    try setBufferScale(client, 5, 2);
    try setBufferTransform(client, 5, @intCast(core.wl_output.transform.@"90"));
    try attachBuffer(client, 5, 7);
    try std.testing.expectEqual(@as(i32, 2), surface.pending_scale);
    try std.testing.expectEqual(@as(i32, 1), surface.current_scale);
    try std.testing.expect(surface_registry.renderState(id) == null);
    try commitSurfaceResource(client, 5);
    const release = try drain(client);
    defer std.testing.allocator.free(release);
    try std.testing.expectEqual(@as(usize, 8), release.len);

    const current_pointer = compositor.currentBuffer(id).?.pixels.ptr;
    const source_cache = surface_registry.renderState(id).?.buffer.source_cache.?;
    try std.testing.expectEqual(@as(i32, 2), surface.current_scale);
    try std.testing.expectEqual(render.BufferTransform.rotate_90, surface.current_transform);
    try std.testing.expectEqual(render.Size{ .width = 4, .height = 6 }, surface.current_logical_size.?);
    try std.testing.expectEqualSlices(u32, &pixels, compositor.currentBuffer(id).?.pixels);
    try std.testing.expectEqual(@as(u64, 2), surface.next_source_version);

    const Case = struct {
        protocol: i32,
        render_transform: render.BufferTransform,
        logical_size: render.Size,
    };
    const cases = [_]Case{
        .{ .protocol = @intCast(core.wl_output.transform.normal), .render_transform = .normal, .logical_size = .{ .width = 6, .height = 4 } },
        .{ .protocol = @intCast(core.wl_output.transform.@"90"), .render_transform = .rotate_90, .logical_size = .{ .width = 4, .height = 6 } },
        .{ .protocol = @intCast(core.wl_output.transform.@"180"), .render_transform = .rotate_180, .logical_size = .{ .width = 6, .height = 4 } },
        .{ .protocol = @intCast(core.wl_output.transform.@"270"), .render_transform = .rotate_270, .logical_size = .{ .width = 4, .height = 6 } },
        .{ .protocol = @intCast(core.wl_output.transform.flipped), .render_transform = .flipped, .logical_size = .{ .width = 6, .height = 4 } },
        .{ .protocol = @intCast(core.wl_output.transform.flipped_90), .render_transform = .flipped_90, .logical_size = .{ .width = 4, .height = 6 } },
        .{ .protocol = @intCast(core.wl_output.transform.flipped_180), .render_transform = .flipped_180, .logical_size = .{ .width = 6, .height = 4 } },
        .{ .protocol = @intCast(core.wl_output.transform.flipped_270), .render_transform = .flipped_270, .logical_size = .{ .width = 4, .height = 6 } },
    };
    for (cases) |case| {
        const old_listener_count = listener_state.committed_count;
        try setBufferTransform(client, 5, case.protocol);
        try std.testing.expectEqual(case.render_transform, surface.pending_transform);
        try std.testing.expectEqual(@as(i32, 2), surface.pending_scale);
        try std.testing.expectEqual(old_listener_count, listener_state.committed_count);
        try commitSurfaceResource(client, 5);

        const state = surface_registry.renderState(id).?;
        try std.testing.expectEqual(case.render_transform, surface.current_transform);
        try std.testing.expectEqual(@as(i32, 2), surface.current_scale);
        try std.testing.expectEqual(case.logical_size, surface.current_logical_size.?);
        try std.testing.expectEqual(case.render_transform, state.transform);
        try std.testing.expectEqual(case.logical_size, state.logical_size);
        try std.testing.expectEqual(render.Size{ .width = 12, .height = 8 }, state.buffer.size);
        try std.testing.expectEqual(current_pointer, state.buffer.pixels.ptr);
        try std.testing.expectEqual(source_cache, state.buffer.source_cache.?);
        try std.testing.expectEqual(@as(u64, 2), surface.next_source_version);
        try std.testing.expectEqual(old_listener_count + 1, listener_state.committed_count);
    }

    const before_scale_state = surface_registry.renderState(id).?;
    const before_scale_listener_count = listener_state.committed_count;
    try requestFrame(client, 5, 8);
    try setBufferScale(client, 5, 4);
    try std.testing.expectEqual(@as(i32, 4), surface.pending_scale);
    try std.testing.expectEqual(@as(i32, 2), surface.current_scale);
    try std.testing.expectEqual(render.Size{ .width = 4, .height = 6 }, surface.current_logical_size.?);
    try std.testing.expectEqual(before_scale_state.logical_size, surface_registry.renderState(id).?.logical_size);
    try std.testing.expectEqual(before_scale_state.buffer.pixels.ptr, surface_registry.renderState(id).?.buffer.pixels.ptr);
    try std.testing.expectEqual(before_scale_listener_count, listener_state.committed_count);
    try std.testing.expectEqual(FrameCallback.State.pending, surface.frame_callbacks.items[0].state);
    try commitSurfaceResource(client, 5);
    const scaled_state = surface_registry.renderState(id).?;
    try std.testing.expectEqual(@as(i32, 4), surface.current_scale);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 3 }, scaled_state.logical_size);
    try std.testing.expectEqual(current_pointer, scaled_state.buffer.pixels.ptr);
    try std.testing.expectEqual(source_cache, scaled_state.buffer.source_cache.?);
    try std.testing.expectEqual(@as(u64, 2), surface.next_source_version);
    try std.testing.expectEqual(FrameCallback.State.committed, surface.frame_callbacks.items[0].state);
    try std.testing.expect(listener_state.last_callbacks_committed);

    try setBufferScale(client, 5, 3);
    try attachBuffer(client, 5, null);
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(i32, 3), surface.current_scale);
    try std.testing.expect(surface.current_logical_size == null);
    try std.testing.expect(surface_registry.renderState(id) == null);
    try std.testing.expectEqual(@as(u64, 2), surface.next_source_version);

    try setBufferScale(client, 5, 7);
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(i32, 7), surface.current_scale);
    try std.testing.expect(surface.current_logical_size == null);
    try std.testing.expect(surface_registry.renderState(id) == null);
    try std.testing.expect(client.fatal() == null);
}

test "zero and negative scale fail immediately without mutating surface state" {
    const Case = struct {
        fn run(invalid_scale: i32) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var surface_registry = SurfaceRegistry.init(std.testing.allocator);
            defer surface_registry.deinit();
            var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
            defer compositor.deinit();
            listener_state.compositor = &compositor;
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }

            try bindCompositorVersion(client, 3, 3);
            try bindShm(&compositor, client, 4);
            try createSurfaceResource(client, 3, 5);
            const id = compositor.surfaceId(client, 5).?;
            const surface = compositor.surfaceForId(id).?;
            const pixels = [_]u32{
                0xff11_0001, 0xff11_0002, 0xff11_0003, 0xff11_0004,
                0xff22_0001, 0xff22_0002, 0xff22_0003, 0xff22_0004,
            };
            const fd = try memfdWithPixels(&pixels);
            defer _ = std.c.close(fd);
            try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
            try createShmBuffer(client, 6, 7, 0, .{ .width = 4, .height = 2 }, 4 * @sizeOf(u32), .argb8888);
            try setBufferScale(client, 5, 2);
            try attachBuffer(client, 5, 7);
            try commitSurfaceResource(client, 5);
            const release = try drain(client);
            defer std.testing.allocator.free(release);

            try setBufferScale(client, 5, 3);
            try setBufferTransform(client, 5, @intCast(core.wl_output.transform.@"90"));
            try requestFrame(client, 5, 8);
            const current_pointer = compositor.currentBuffer(id).?.pixels.ptr;
            const current_cache = surface_registry.renderState(id).?.buffer.source_cache.?;
            const listener_count = listener_state.committed_count;
            try setBufferScale(client, 5, invalid_scale);

            const fatal = client.fatal().?;
            try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
            try std.testing.expectEqual(
                @as(?u32, @intCast(core.wl_surface.@"error".invalid_scale)),
                fatal.protocol_code,
            );
            try std.testing.expectEqual(@as(u32, 5), fatal.object_id);
            try std.testing.expectEqual(@as(i32, 3), surface.pending_scale);
            try std.testing.expectEqual(@as(i32, 2), surface.current_scale);
            try std.testing.expectEqual(render.BufferTransform.rotate_90, surface.pending_transform);
            try std.testing.expectEqual(render.BufferTransform.normal, surface.current_transform);
            try std.testing.expectEqual(render.Size{ .width = 2, .height = 1 }, surface.current_logical_size.?);
            try std.testing.expectEqual(current_pointer, compositor.currentBuffer(id).?.pixels.ptr);
            try std.testing.expectEqual(current_cache, surface_registry.renderState(id).?.buffer.source_cache.?);
            try std.testing.expectEqual(listener_count, listener_state.committed_count);
            try std.testing.expectEqual(@as(usize, 1), surface.frame_callbacks.items.len);
            try std.testing.expectEqual(FrameCallback.State.pending, surface.frame_callbacks.items[0].state);
        }
    };

    try Case.run(0);
    try Case.run(-1);
}

test "frame callback materializes immediately and waits for null commit completion" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try createSurfaceResource(client, 3, 4);
    const id = compositor.surfaceId(client, 4).?;
    const surface = compositor.surfaceForId(id).?;
    try compositor.replaceSurfaceResourceForTest(client, surface, 4);
    const completion = listener_state.frame_completion.?;
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&compositor)), completion.context);

    try requestFrame(client, 4, 5);
    try std.testing.expect(client.fatal() == null);
    try std.testing.expectEqual(@as(usize, 1), surface.frame_callbacks.items.len);
    const callback = surface.frame_callbacks.items[0];
    try std.testing.expectEqual(FrameCallback.State.pending, callback.state);
    try std.testing.expectEqual(@as(u32, 1), callback.resource.version());
    try std.testing.expectEqual(&callback.resource.runtime, client.lookup(5).?);

    completion.complete(completion.context, id, 10);
    const before_commit = try drain(client);
    defer std.testing.allocator.free(before_commit);
    try std.testing.expectEqual(@as(usize, 0), before_commit.len);
    try std.testing.expectEqual(FrameCallback.State.pending, callback.state);

    try commitSurfaceResource(client, 4);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);
    try std.testing.expect(listener_state.last_size == null);
    try std.testing.expect(listener_state.last_callbacks_committed);
    try std.testing.expectEqual(@as(usize, 1), listener_state.callbacks_committed_count);
    try std.testing.expectEqual(FrameCallback.State.committed, callback.state);
    const no_automatic_done = try drain(client);
    defer std.testing.allocator.free(no_automatic_done);
    try std.testing.expectEqual(@as(usize, 0), no_automatic_done.len);

    completion.complete(completion.context, id, 0xaabb_ccdd);
    const completed = try drain(client);
    defer std.testing.allocator.free(completed);
    try std.testing.expectEqual(@as(usize, 24), completed.len);
    try expectCallbackDoneAndDelete(completed, 0, 5, 0xaabb_ccdd);
    try std.testing.expectEqual(@as(usize, 0), surface.frame_callbacks.items.len);
    try std.testing.expect(client.lookup(5) == null);

    completion.complete(completion.context, id, 99);
    const completed_again = try drain(client);
    defer std.testing.allocator.free(completed_again);
    try std.testing.expectEqual(@as(usize, 0), completed_again.len);
    try commitSurfaceResource(client, 4);
    try std.testing.expectEqual(@as(usize, 2), listener_state.committed_count);
    try std.testing.expect(!listener_state.last_callbacks_committed);
    try std.testing.expectEqual(@as(usize, 1), listener_state.callbacks_committed_count);
    try std.testing.expect(client.fatal() == null);
}

test "prepared callback boundary leaves later requests pending and preserves order across commits" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try createSurfaceResource(client, 3, 4);
    const id = compositor.surfaceId(client, 4).?;
    const surface = compositor.surfaceForId(id).?;
    const completion = listener_state.frame_completion.?;
    try requestFrame(client, 4, 5);
    try requestFrame(client, 4, 6);
    var prepared = try compositor.prepareCommit(surface);
    defer prepared.deinit();
    try requestFrame(client, 4, 7);
    const token: UpdateToken = .{ .surface = id, .sequence = 1 };
    surface.frame_callbacks.items[0].state = .{ .queued = token };
    surface.frame_callbacks.items[1].state = .{ .queued = token };
    compositor.publishPreparedCommit(surface, &prepared, token, true);

    try std.testing.expectEqual(FrameCallback.State.committed, surface.frame_callbacks.items[0].state);
    try std.testing.expectEqual(FrameCallback.State.committed, surface.frame_callbacks.items[1].state);
    try std.testing.expectEqual(FrameCallback.State.pending, surface.frame_callbacks.items[2].state);
    try std.testing.expect(listener_state.last_callbacks_committed);
    completion.complete(completion.context, id, 100);
    const first_completion = try drain(client);
    defer std.testing.allocator.free(first_completion);
    try std.testing.expectEqual(@as(usize, 48), first_completion.len);
    try expectCallbackDoneAndDelete(first_completion, 0, 5, 100);
    try expectCallbackDoneAndDelete(first_completion, 24, 6, 100);
    try std.testing.expectEqual(@as(usize, 1), surface.frame_callbacks.items.len);
    try std.testing.expectEqual(@as(u32, 7), surface.frame_callbacks.items[0].resource.id());
    try std.testing.expectEqual(FrameCallback.State.pending, surface.frame_callbacks.items[0].state);

    try requestFrame(client, 4, 8);
    completion.complete(completion.context, id, 101);
    const still_pending = try drain(client);
    defer std.testing.allocator.free(still_pending);
    try std.testing.expectEqual(@as(usize, 0), still_pending.len);
    try std.testing.expectEqual(FrameCallback.State.pending, surface.frame_callbacks.items[0].state);
    try std.testing.expectEqual(FrameCallback.State.pending, surface.frame_callbacks.items[1].state);

    try commitSurfaceResource(client, 4);
    try std.testing.expectEqual(@as(usize, 2), listener_state.committed_count);
    try std.testing.expectEqual(@as(usize, 2), listener_state.callbacks_committed_count);
    completion.complete(completion.context, id, 102);
    const second_completion = try drain(client);
    defer std.testing.allocator.free(second_completion);
    try std.testing.expectEqual(@as(usize, 48), second_completion.len);
    try expectCallbackDoneAndDelete(second_completion, 0, 7, 102);
    try expectCallbackDoneAndDelete(second_completion, 24, 8, 102);
    try std.testing.expectEqual(@as(usize, 0), surface.frame_callbacks.items.len);
    try std.testing.expect(client.fatal() == null);
}

test "frame callback allocation failure leaves no resource or list storage" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var compositor: WayringCompositor = undefined;
    try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, null);
    defer compositor.deinit();
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try createSurfaceResource(client, 3, 4);
    const surface = compositor.findClient(client).?.surfaces.items[0];
    const live_before = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    const frame = try encode(4, 3, &core.wl_surface.request_messages[3], &.{
        .{ .new_id = .{ .typed = 5 } },
    });
    defer std.testing.allocator.free(frame);
    try client.receive(frame, &.{});
    // Capacity reservation succeeds, then callback allocation fails. The
    // pre-materialization rollback must reclaim both allocations.
    compositor_allocator.fail_index = compositor_allocator.alloc_index + 1;
    try client.dispatch();

    try std.testing.expect(compositor_allocator.has_induced_failure);
    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expectEqual(@as(usize, 0), surface.frame_callbacks.items.len);
    try std.testing.expectEqual(@as(usize, 0), surface.frame_callbacks.capacity);
    try std.testing.expect(client.lookup(5) == null);
    try std.testing.expectEqual(live_before, compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes);
}

test "done enqueue failure terminalizes client and still frees callback" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    var client_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const managed = try server.CoreClient.create(client_allocator.allocator(), &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try createSurfaceResource(client, 3, 4);
    const id = compositor.surfaceId(client, 4).?;
    const surface = compositor.surfaceForId(id).?;
    const live_before_frame = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    try requestFrame(client, 4, 5);
    try commitSurfaceResource(client, 4);
    const before_failure = try drain(client);
    defer std.testing.allocator.free(before_failure);
    try std.testing.expectEqual(@as(usize, 0), before_failure.len);
    const live_with_frame = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    try std.testing.expect(live_with_frame >= live_before_frame + @sizeOf(FrameCallback));

    client_allocator.fail_index = client_allocator.alloc_index;
    const completion = listener_state.frame_completion.?;
    completion.complete(completion.context, id, 55);

    try std.testing.expect(client_allocator.has_induced_failure);
    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expectEqual(@as(usize, 0), surface.frame_callbacks.items.len);
    try std.testing.expect(client.lookup(5) == null);
    try std.testing.expectEqual(
        live_with_frame - @sizeOf(FrameCallback),
        compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
    );
}

test "surface destroy and disconnect retire pending and committed callbacks without done" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const first = try server.CoreClient.create(std.testing.allocator, &host, .{});
    var first_live = true;
    defer if (first_live) {
        compositor.destroyClientResources(first.client());
        first.destroy();
    };
    const second = try server.CoreClient.create(std.testing.allocator, &host, .{});
    var second_live = true;
    defer if (second_live) {
        compositor.destroyClientResources(second.client());
        second.destroy();
    };

    try bindCompositor(first.client(), 3);
    try createSurfaceResource(first.client(), 3, 4);
    const stale_id = compositor.surfaceId(first.client(), 4).?;
    const stale_completion = listener_state.frame_completion.?;
    try requestFrame(first.client(), 4, 5);
    try commitSurfaceResource(first.client(), 4);
    try requestFrame(first.client(), 4, 6);
    try send(first.client(), 4, 0, &core.wl_surface.request_messages[0], &.{});
    const explicit_destroy = try drain(first.client());
    defer std.testing.allocator.free(explicit_destroy);
    try expectDeleteIds(explicit_destroy, &.{ 5, 6, 4 });
    try std.testing.expect(first.client().lookup(5) == null);
    try std.testing.expect(first.client().lookup(6) == null);
    try std.testing.expect(!compositor.containsSurface(stale_id));

    try bindCompositor(second.client(), 3);
    try createSurfaceResource(second.client(), 3, 4);
    const current_id = compositor.surfaceId(second.client(), 4).?;
    try std.testing.expectEqual(stale_id.index, current_id.index);
    try std.testing.expect(stale_id.generation != current_id.generation);
    try requestFrame(second.client(), 4, 5);
    try commitSurfaceResource(second.client(), 4);
    try requestFrame(second.client(), 4, 6);
    stale_completion.complete(stale_completion.context, stale_id, 70);
    const stale_noop = try drain(second.client());
    defer std.testing.allocator.free(stale_noop);
    try std.testing.expectEqual(@as(usize, 0), stale_noop.len);
    try std.testing.expectEqual(@as(usize, 2), compositor.surfaceForId(current_id).?.frame_callbacks.items.len);

    const current_completion = listener_state.frame_completion.?;
    compositor.destroyClientResources(second.client());
    try std.testing.expect(!compositor.containsSurface(current_id));
    try std.testing.expect(second.client().lookup(5) == null);
    try std.testing.expect(second.client().lookup(6) == null);
    const disconnected = try drain(second.client());
    defer std.testing.allocator.free(disconnected);
    try expectDeleteIds(disconnected, &.{ 5, 6, 4, 3 });
    current_completion.complete(current_completion.context, current_id, 71);
    const removed_noop = try drain(second.client());
    defer std.testing.allocator.free(removed_noop);
    try std.testing.expectEqual(@as(usize, 0), removed_noop.len);
    second.destroy();
    second_live = false;

    compositor.destroyClientResources(first.client());
    first.destroy();
    first_live = false;
    try std.testing.expectEqual(@as(usize, 2), listener_state.removing_count);
}

test "scanner wl_region inherits compositor version and owns rectangle state through teardown" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, null);
    defer compositor.deinit();
    const first = try server.CoreClient.create(std.testing.allocator, &host, .{});
    var first_live = true;
    defer if (first_live) {
        compositor.destroyClientResources(first.client());
        first.destroy();
    };
    const second = try server.CoreClient.create(std.testing.allocator, &host, .{});
    var second_live = true;
    defer if (second_live) {
        compositor.destroyClientResources(second.client());
        second.destroy();
    };

    try bindCompositor(first.client(), 3);
    try createRegionResource(first.client(), 3, 4);
    try createSurfaceResource(first.client(), 3, 5);
    const first_objects = compositor.findClient(first.client()).?;
    try std.testing.expectEqual(@as(u32, 1), first_objects.compositors.items[0].resource.version());
    try std.testing.expectEqual(@as(u32, 1), first_objects.regions.items[0].resource.version());
    try std.testing.expectEqual(@as(u32, 1), first_objects.surfaces.items[0].resource.version());

    try addRegion(first.client(), 4, 0, 0, 10, 10);
    try addRegion(first.client(), 4, 50, 50, 0, 4);
    try subtractRegion(first.client(), 4, 2, 2, 4, 4);
    try subtractRegion(first.client(), 4, 0, 0, -1, 9);
    const region = first_objects.regions.items[0];
    try std.testing.expect(region.value.contains(1, 1));
    try std.testing.expect(!region.value.contains(3, 3));
    try std.testing.expect(!region.value.contains(50, 50));
    try std.testing.expect(first.client().fatal() == null);

    try send(first.client(), 4, 0, &core.wl_region.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 0), first_objects.regions.items.len);
    try std.testing.expect(first.client().lookup(4) == null);
    try send(first.client(), 5, 0, &core.wl_surface.request_messages[0], &.{});

    try bindCompositor(second.client(), 3);
    const second_objects = compositor.findClient(second.client()).?;
    try compositor.replaceCompositorResourceForTest(second.client(), second_objects.compositors.items[0], 4);
    try createRegionResource(second.client(), 3, 4);
    try createSurfaceResource(second.client(), 3, 5);
    try std.testing.expectEqual(@as(u32, 4), second_objects.regions.items[0].resource.version());
    try std.testing.expectEqual(@as(u32, 4), second_objects.surfaces.items[0].resource.version());
    try std.testing.expectEqual(@as(usize, 1), compositor.regionCount());

    compositor.destroyClientResources(second.client());
    second.destroy();
    second_live = false;
    try std.testing.expectEqual(@as(usize, 0), compositor.regionCount());
    try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());
    compositor.destroyClientResources(first.client());
    first.destroy();
    first_live = false;
}

test "surface regions copy immediately and persist with null and explicit-empty input semantics" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try createSurfaceResource(client, 3, 4);
    try createRegionResource(client, 3, 5);
    try createRegionResource(client, 3, 6);
    try addRegion(client, 5, 1, 2, 5, 6);
    try setSurfaceRegion(client, 4, 4, 5);
    try setSurfaceRegion(client, 4, 5, 5);

    const surface = compositor.findClient(client).?.surfaces.items[0];
    try std.testing.expect(surface.current_opaque.isEmpty());
    try std.testing.expect(surface.current_input.infinite);
    try std.testing.expect(surface.pending_opaque.contains(2, 3));
    try std.testing.expect(!surface.pending_input.infinite);
    try std.testing.expect(surface.pending_input.value.contains(2, 3));

    try subtractRegion(client, 5, 1, 2, 5, 6);
    try send(client, 5, 0, &core.wl_region.request_messages[0], &.{});
    try std.testing.expect(surface.pending_opaque.contains(2, 3));
    try std.testing.expect(surface.pending_input.value.contains(2, 3));
    try commitSurfaceResource(client, 4);
    try std.testing.expect(surface.current_opaque.contains(2, 3));
    try std.testing.expect(!surface.current_input.infinite);
    try std.testing.expect(surface.current_input.value.contains(2, 3));
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);
    try std.testing.expect(listener_state.last_size == null);

    try commitSurfaceResource(client, 4);
    try std.testing.expect(surface.current_opaque.contains(2, 3));
    try std.testing.expect(surface.current_input.value.contains(2, 3));
    try std.testing.expectEqual(@as(usize, 2), listener_state.committed_count);

    try setSurfaceRegion(client, 4, 4, null);
    try setSurfaceRegion(client, 4, 5, null);
    try std.testing.expect(surface.current_opaque.contains(2, 3));
    try std.testing.expect(!surface.current_input.infinite);
    try commitSurfaceResource(client, 4);
    try std.testing.expect(surface.current_opaque.isEmpty());
    try std.testing.expect(surface.current_input.infinite);

    try setSurfaceRegion(client, 4, 5, 6);
    try commitSurfaceResource(client, 4);
    try std.testing.expect(!surface.current_input.infinite);
    try std.testing.expect(surface.current_input.value.isEmpty());
    try std.testing.expectEqual(@as(usize, 4), listener_state.committed_count);
    try std.testing.expectEqual(@as(usize, 1), compositor.regionCount());
}

test "surface region object validation rejects wrong foreign and non-Wayring resources" {
    const WrongInterface = struct {
        fn run() !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var registry = SurfaceRegistry.init(std.testing.allocator);
            defer registry.deinit();
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &registry, null);
            defer compositor.deinit();
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            defer {
                compositor.destroyClientResources(managed.client());
                managed.destroy();
            }
            try bindCompositor(managed.client(), 3);
            try createSurfaceResource(managed.client(), 3, 4);
            try setSurfaceRegion(managed.client(), 4, 4, 3);
            try std.testing.expectEqual(server.Fatal.Kind.protocol, managed.client().fatal().?.kind);
            try std.testing.expect(compositor.findClient(managed.client()).?.surfaces.items[0].current_opaque.isEmpty());
        }
    };
    const Foreign = struct {
        fn run() !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var registry = SurfaceRegistry.init(std.testing.allocator);
            defer registry.deinit();
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &registry, null);
            defer compositor.deinit();
            const owner = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const other = try server.CoreClient.create(std.testing.allocator, &host, .{});
            defer {
                compositor.destroyClientResources(other.client());
                other.destroy();
                compositor.destroyClientResources(owner.client());
                owner.destroy();
            }
            try bindCompositor(owner.client(), 3);
            try createSurfaceResource(owner.client(), 3, 4);
            try createRegionResource(owner.client(), 3, 5);
            try bindCompositor(other.client(), 3);
            try createSurfaceResource(other.client(), 3, 4);
            try setSurfaceRegion(other.client(), 4, 5, 5);
            try std.testing.expectEqual(server.Fatal.Kind.protocol, other.client().fatal().?.kind);
            try std.testing.expect(compositor.findClient(other.client()).?.surfaces.items[0].current_input.infinite);
        }
    };
    const Impostor = struct {
        fn run() !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var registry = SurfaceRegistry.init(std.testing.allocator);
            defer registry.deinit();
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &registry, null);
            defer compositor.deinit();
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            var managed_live = true;
            defer if (managed_live) {
                compositor.destroyClientResources(client);
                managed.destroy();
            };
            try bindCompositor(client, 3);
            try createSurfaceResource(client, 3, 4);
            var impostor: core.wl_region.Resource = .init(std.testing.allocator, 5, 1, .client, client.ownerHooks());
            try client.installClientInitial(5, &impostor.runtime);
            try setSurfaceRegion(client, 4, 4, 5);
            try std.testing.expectEqual(server.Fatal.Kind.implementation, client.fatal().?.kind);
            try std.testing.expect(compositor.findClient(client).?.surfaces.items[0].current_opaque.isEmpty());
            compositor.destroyClientResources(client);
            impostor.destroy();
            impostor.deinit();
            managed.destroy();
            managed_live = false;
        }
    };

    try WrongInterface.run();
    try Foreign.run();
    try Impostor.run();
}

test "wl_region creation OOM rolls back reservation list and storage" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var compositor: WayringCompositor = undefined;
    try compositor.init(failing.allocator(), &host, &registry, null);
    defer compositor.deinit();
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    defer {
        compositor.destroyClientResources(managed.client());
        managed.destroy();
    }

    try bindCompositor(managed.client(), 3);
    const live_before = failing.allocated_bytes - failing.freed_bytes;
    failing.fail_index = failing.alloc_index;
    try createRegionResource(managed.client(), 3, 4);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, managed.client().fatal().?.kind);
    try std.testing.expectEqual(@as(usize, 0), compositor.regionCount());
    try std.testing.expect(managed.client().lookup(4) == null);
    try std.testing.expectEqual(live_before, failing.allocated_bytes - failing.freed_bytes);
}

test "scanner-backed surfaces use canonical registry IDs without Wayring lookup confusion" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var synthetic: SyntheticRegistryProvider = .{ .pixel = 0xff11_2233 };
    const synthetic_id = try surface_registry.add(synthetic.provider());
    defer surface_registry.remove(synthetic_id);
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, null);
    defer compositor.deinit();
    const first = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const second = try server.CoreClient.create(std.testing.allocator, &host, .{});
    defer {
        compositor.destroyClientResources(second.client());
        second.destroy();
        compositor.destroyClientResources(first.client());
        first.destroy();
    }

    try bindCompositor(first.client(), 3);
    try bindCompositor(second.client(), 3);
    try send(first.client(), 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 4 } }});
    try send(second.client(), 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 4 } }});
    const first_id = compositor.surfaceId(first.client(), 4).?;
    const second_id = compositor.surfaceId(second.client(), 4).?;
    try std.testing.expect(!std.meta.eql(first_id, synthetic_id));
    try std.testing.expect(!std.meta.eql(first_id, second_id));
    try std.testing.expect(!compositor.containsSurface(synthetic_id));
    try std.testing.expectEqual(@as(?*CopiedBufferSnapshot, null), compositor.currentBuffer(synthetic_id));
    try std.testing.expectEqual(@as(u32, 0xff11_2233), surface_registry.renderState(synthetic_id).?.buffer.pixels[0]);
    try std.testing.expect(surface_registry.contains(first_id));
    try std.testing.expect(surface_registry.contains(second_id));
    try std.testing.expectEqual(@as(usize, 2), compositor.surfaceCount());

    try send(first.client(), 4, 0, &core.wl_surface.request_messages[0], &.{});
    try std.testing.expect(!compositor.containsSurface(first_id));
    try std.testing.expect(!surface_registry.contains(first_id));
    try std.testing.expect(compositor.containsSurface(second_id));
    const events = try drain(first.client());
    defer std.testing.allocator.free(events);
    try std.testing.expectEqual(@as(usize, 12), events.len);
    try std.testing.expectEqual(@as(u32, 1), word(events, 0));
    try std.testing.expectEqual(@as(u16, 1), @as(u16, @truncate(word(events, 4))));
    try std.testing.expectEqual(@as(u32, 4), word(events, 8));

    try send(first.client(), 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 4 } }});
    const replacement_id = compositor.surfaceId(first.client(), 4).?;
    try std.testing.expect(!std.meta.eql(first_id, replacement_id));
    try std.testing.expectEqual(first_id.index, replacement_id.index);
    try std.testing.expect(first_id.generation != replacement_id.generation);
    try std.testing.expect(!compositor.containsSurface(first_id));
    try std.testing.expect(compositor.containsSurface(replacement_id));

    try send(second.client(), 4, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = null },
        .{ .int = 0 },
        .{ .int = 0 },
    });
    try send(second.client(), 4, 6, &core.wl_surface.request_messages[6], &.{});
    try std.testing.expect(second.client().fatal() == null);
    try std.testing.expectEqual(@as(?*CopiedBufferSnapshot, null), compositor.currentBuffer(second_id));
}

test "surface creation OOM before registration leaves no provider or listener entry" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    const live_before = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    compositor_allocator.fail_index = compositor_allocator.alloc_index;
    try createSurfaceResource(client, 3, 4);

    try std.testing.expect(compositor_allocator.has_induced_failure);
    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expectEqual(@as(usize, 0), listener_state.added_count);
    try std.testing.expectEqual(@as(usize, 0), listener_state.removing_count);
    try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());
    try std.testing.expectEqual(@as(usize, 0), surface_registry.len());
    try std.testing.expect(client.lookup(4) == null);
    try std.testing.expectEqual(live_before, compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes);
}

test "surface registry allocation failure rolls back stable provider context before listener" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var surface_registry = SurfaceRegistry.init(registry_allocator.allocator());
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    registry_allocator.fail_index = registry_allocator.alloc_index;
    try createSurfaceResource(client, 3, 4);

    try std.testing.expect(registry_allocator.has_induced_failure);
    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expectEqual(@as(usize, 0), listener_state.added_count);
    try std.testing.expectEqual(@as(usize, 0), listener_state.removing_count);
    try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());
    try std.testing.expectEqual(@as(usize, 0), surface_registry.len());
    try std.testing.expect(client.lookup(4) == null);
}

test "listener-added failure unregisters provider without calling removing" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{
        .registry = &surface_registry,
        .fail_added = true,
        .require_owned_lookup_on_remove = false,
    };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try createSurfaceResource(client, 3, 4);

    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expectEqual(@as(usize, 1), listener_state.added_count);
    try std.testing.expectEqual(@as(usize, 0), listener_state.removing_count);
    try std.testing.expectEqualSlices(TestPresentationListener.Event, &.{.added}, listener_state.events[0..listener_state.event_count]);
    try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());
    try std.testing.expectEqual(@as(usize, 0), surface_registry.len());
    try std.testing.expect(client.lookup(4) == null);
    const stale_completion = listener_state.frame_completion.?;
    stale_completion.complete(stale_completion.context, listener_state.last_id.?, 1);
}

test "post-added resource-list materialization OOM removes listener before provider rollback" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var listener_state: TestPresentationListener = .{
        .registry = &surface_registry,
        .require_owned_lookup_on_remove = false,
    };
    var compositor: WayringCompositor = undefined;
    try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    const live_before = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    compositor_allocator.fail_index = compositor_allocator.alloc_index + 1;
    try createSurfaceResource(client, 3, 4);

    try std.testing.expect(compositor_allocator.has_induced_failure);
    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expectEqual(@as(usize, 1), listener_state.added_count);
    try std.testing.expectEqual(@as(usize, 1), listener_state.removing_count);
    try std.testing.expectEqualSlices(
        TestPresentationListener.Event,
        &.{ .added, .removing },
        listener_state.events[0..listener_state.event_count],
    );
    try std.testing.expect(!listener_state.removing_had_render_state);
    try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());
    try std.testing.expectEqual(@as(usize, 0), surface_registry.len());
    try std.testing.expect(client.lookup(4) == null);
    try std.testing.expectEqual(live_before, compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes);
}

test "scanner pending replacements never release and clean live and destroyed buffer pins" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try bindShm(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    const id = compositor.surfaceId(client, 5).?;
    const surface = compositor.surfaceForId(id).?;
    const pixels = [_]u32{ 0xff11_2233, 0xff44_5566 };
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
    try createShmBuffer(client, 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
    try createShmBuffer(client, 6, 8, @sizeOf(u32), .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);

    try attachBuffer(client, 5, 7);
    try attachBuffer(client, 5, 8);
    const no_replacement_release = try drain(client);
    defer std.testing.allocator.free(no_replacement_release);
    try std.testing.expectEqual(@as(usize, 0), no_replacement_release.len);
    try std.testing.expectEqual(client.lookup(8).?, surface.pending_attachment.?.resource.?);
    try std.testing.expect(surface.pending_attachment.?.observer != null);

    const live_before_replaced_destroy = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    try send(client, 7, 0, &core.wl_buffer.request_messages[0], &.{});
    try std.testing.expectEqual(
        live_before_replaced_destroy - @sizeOf(server.shm.Buffer),
        compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
    );
    const replaced_delete_id = try drain(client);
    defer std.testing.allocator.free(replaced_delete_id);
    try std.testing.expectEqual(@as(usize, 12), replaced_delete_id.len);

    try commitSurfaceResource(client, 5);
    const committed_release = try drain(client);
    defer std.testing.allocator.free(committed_release);
    try std.testing.expectEqual(@as(usize, 8), committed_release.len);
    try std.testing.expectEqual(@as(u32, 8), word(committed_release, 0));
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);

    try createShmBuffer(client, 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
    try attachBuffer(client, 5, 7);
    try attachBuffer(client, 5, null);
    const no_null_replacement_release = try drain(client);
    defer std.testing.allocator.free(no_null_replacement_release);
    try std.testing.expectEqual(@as(usize, 0), no_null_replacement_release.len);
    try std.testing.expect(surface.pending_attachment == null);
    try std.testing.expect(surface.has_pending_attachment);

    const live_before_null_replaced_destroy = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    try send(client, 7, 0, &core.wl_buffer.request_messages[0], &.{});
    try std.testing.expectEqual(
        live_before_null_replaced_destroy - @sizeOf(server.shm.Buffer),
        compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
    );
    const null_replaced_delete_id = try drain(client);
    defer std.testing.allocator.free(null_replaced_delete_id);
    try std.testing.expectEqual(@as(usize, 12), null_replaced_delete_id.len);

    try createShmBuffer(client, 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
    try attachBuffer(client, 5, 7);
    try send(client, 7, 0, &core.wl_buffer.request_messages[0], &.{});
    try std.testing.expect(surface.pending_attachment != null);
    try std.testing.expect(surface.pending_attachment.?.resource == null);
    try std.testing.expect(surface.pending_attachment.?.observer == null);
    try std.testing.expect(surface.pending_attachment.?.pin.buffer != null);
    const destroyed_pending_delete_id = try drain(client);
    defer std.testing.allocator.free(destroyed_pending_delete_id);
    try std.testing.expectEqual(@as(usize, 12), destroyed_pending_delete_id.len);
    const live_with_destroyed_pending_pin = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;

    try attachBuffer(client, 5, null);
    try std.testing.expectEqual(
        live_with_destroyed_pending_pin - @sizeOf(server.shm.Buffer),
        compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
    );
    const no_destroyed_replacement_release = try drain(client);
    defer std.testing.allocator.free(no_destroyed_replacement_release);
    try std.testing.expectEqual(@as(usize, 0), no_destroyed_replacement_release.len);
    try commitSurfaceResource(client, 5);
    try std.testing.expect(compositor.currentBuffer(id) == null);
    try std.testing.expectEqual(@as(usize, 2), listener_state.committed_count);
}

test "v1 through v4 attach replaces offset across null replacement destroy and failure" {
    const Case = struct {
        fn run(version: u32) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var surface_registry = SurfaceRegistry.init(std.testing.allocator);
            defer surface_registry.deinit();
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &surface_registry, null);
            defer compositor.deinit();
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }

            try bindCompositor(client, 3);
            try bindShm(&compositor, client, 4);
            try createSurfaceResource(client, 3, 5);
            const id = compositor.surfaceId(client, 5).?;
            const surface = compositor.surfaceForId(id).?;
            try compositor.replaceSurfaceResourceForTest(client, surface, version);
            const pixels = [_]u32{ 0xff11_2233, 0xff44_5566 };
            const fd = try memfdWithPixels(&pixels);
            defer _ = std.c.close(fd);
            try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
            try createShmBuffer(client, 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
            try createShmBuffer(client, 6, 8, @sizeOf(u32), .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);

            try attachBufferAt(client, 5, 7, -7, 9);
            try std.testing.expect(client.fatal() == null);
            try std.testing.expectEqual(version, surface.resource.version());
            try std.testing.expect(surface.has_pending_attachment);
            try std.testing.expectEqual(@as(i32, -7), surface.pending_offset_x);
            try std.testing.expectEqual(@as(i32, 9), surface.pending_offset_y);
            try std.testing.expectEqual(client.lookup(7).?, surface.pending_attachment.?.resource.?);
            const no_events = try drain(client);
            defer std.testing.allocator.free(no_events);
            try std.testing.expectEqual(@as(usize, 0), no_events.len);

            try attachBufferAt(client, 5, null, 3, 4);
            try std.testing.expect(surface.has_pending_attachment);
            try std.testing.expect(surface.pending_attachment == null);
            try std.testing.expectEqual(@as(i32, 3), surface.pending_offset_x);
            try std.testing.expectEqual(@as(i32, 4), surface.pending_offset_y);

            try attachBufferAt(client, 5, 8, 5, -6);
            try std.testing.expectEqual(@as(i32, 5), surface.pending_offset_x);
            try std.testing.expectEqual(@as(i32, -6), surface.pending_offset_y);
            try std.testing.expectEqual(client.lookup(8).?, surface.pending_attachment.?.resource.?);
            try send(client, 8, 0, &core.wl_buffer.request_messages[0], &.{});
            try std.testing.expect(surface.pending_attachment.?.resource == null);
            try std.testing.expect(surface.pending_attachment.?.observer == null);
            try std.testing.expectEqual(@as(i32, 5), surface.pending_offset_x);
            try std.testing.expectEqual(@as(i32, -6), surface.pending_offset_y);
            const destroyed_buffer = try drain(client);
            defer std.testing.allocator.free(destroyed_buffer);
            try expectDeleteIds(destroyed_buffer, &.{8});

            try attachBufferAt(client, 5, 7, -11, 12);
            try std.testing.expectEqual(@as(i32, -11), surface.pending_offset_x);
            try std.testing.expectEqual(@as(i32, 12), surface.pending_offset_y);
            try commitSurfaceResource(client, 5);
            try std.testing.expect(!surface.has_pending_attachment);
            try std.testing.expect(surface.pending_attachment == null);
            try std.testing.expectEqual(@as(i32, 0), surface.pending_offset_x);
            try std.testing.expectEqual(@as(i32, 0), surface.pending_offset_y);
            try std.testing.expectEqual(@as(i32, -11), surface.current_offset_x);
            try std.testing.expectEqual(@as(i32, 12), surface.current_offset_y);
            const release = try drain(client);
            defer std.testing.allocator.free(release);
            try std.testing.expectEqual(@as(usize, 8), release.len);

            try createShmBuffer(client, 6, 8, @sizeOf(u32), .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
            try attachBufferAt(client, 5, 8, 13, -14);
            compositor.commit_fault = .copy;
            try commitSurfaceResource(client, 5);
            try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
            try std.testing.expect(!surface.has_pending_attachment);
            try std.testing.expect(surface.pending_attachment == null);
            try std.testing.expectEqual(@as(i32, 13), surface.pending_offset_x);
            try std.testing.expectEqual(@as(i32, -14), surface.pending_offset_y);
            try std.testing.expectEqual(@as(i32, -11), surface.current_offset_x);
            try std.testing.expectEqual(@as(i32, 12), surface.current_offset_y);
        }
    };

    for (1..5) |version| try Case.run(@intCast(version));
}

test "v5 offset transactions survive attach replacement and publish exact applied metadata" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositorVersion(client, 3, 5);
    try bindShm(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    const id = compositor.surfaceId(client, 5).?;
    const surface = compositor.surfaceForId(id).?;
    const pixels = [_]u32{ 0xff11_2233, 0xff44_5566 };
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
    try createShmBuffer(client, 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
    try createShmBuffer(client, 6, 8, @sizeOf(u32), .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);

    try setSurfaceOffset(client, 5, -7, 9);
    try attachBuffer(client, 5, 7);
    try std.testing.expectEqual(@as(i32, -7), surface.pending_offset_x);
    try std.testing.expectEqual(@as(i32, 9), surface.pending_offset_y);
    var first_prepared = PreparedCommit.init(surface);
    defer first_prepared.deinit();
    try std.testing.expectEqual(@as(i32, -7), first_prepared.offset_x);
    try std.testing.expectEqual(@as(i32, 9), first_prepared.offset_y);
    try std.testing.expectEqual(@as(i32, 0), surface.current_offset_x);
    try std.testing.expectEqual(@as(i32, 0), surface.current_offset_y);

    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(i32, 0), surface.pending_offset_x);
    try std.testing.expectEqual(@as(i32, 0), surface.pending_offset_y);
    try std.testing.expectEqual(@as(i32, -7), surface.current_offset_x);
    try std.testing.expectEqual(@as(i32, 9), surface.current_offset_y);
    const first_release = try drain(client);
    defer std.testing.allocator.free(first_release);
    try std.testing.expectEqual(@as(usize, 8), first_release.len);
    try std.testing.expectEqual(@as(u32, 7), word(first_release, 0));

    const current_pointer = compositor.currentBuffer(id).?.pixels.ptr;
    const current_cache = surface_registry.renderState(id).?.buffer.source_cache.?;
    const next_source_version = surface.next_source_version;
    const committed_count = listener_state.committed_count;
    try requestFrame(client, 5, 9);
    try setSurfaceOffset(client, 5, 4, -5);
    var state_prepared = PreparedCommit.init(surface);
    defer state_prepared.deinit();
    try std.testing.expectEqual(@as(i32, 4), state_prepared.offset_x);
    try std.testing.expectEqual(@as(i32, -5), state_prepared.offset_y);
    try commitSurfaceResource(client, 5);

    try std.testing.expectEqual(committed_count + 1, listener_state.committed_count);
    try std.testing.expect(listener_state.last_callbacks_committed);
    try std.testing.expectEqual(FrameCallback.State.committed, surface.frame_callbacks.items[0].state);
    try std.testing.expectEqual(@as(i32, 0), surface.pending_offset_x);
    try std.testing.expectEqual(@as(i32, 0), surface.pending_offset_y);
    try std.testing.expectEqual(@as(i32, 4), surface.current_offset_x);
    try std.testing.expectEqual(@as(i32, -5), surface.current_offset_y);
    try std.testing.expectEqual(current_pointer, compositor.currentBuffer(id).?.pixels.ptr);
    try std.testing.expectEqual(current_cache, surface_registry.renderState(id).?.buffer.source_cache.?);
    try std.testing.expectEqual(next_source_version, surface.next_source_version);
    const no_state_release = try drain(client);
    defer std.testing.allocator.free(no_state_release);
    try std.testing.expectEqual(@as(usize, 0), no_state_release.len);

    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(i32, 0), surface.current_offset_x);
    try std.testing.expectEqual(@as(i32, 0), surface.current_offset_y);
    try std.testing.expectEqual(current_pointer, compositor.currentBuffer(id).?.pixels.ptr);
    try std.testing.expectEqual(next_source_version, surface.next_source_version);

    try setSurfaceOffset(client, 5, 11, 12);
    try attachBuffer(client, 5, null);
    try std.testing.expectEqual(@as(i32, 11), surface.pending_offset_x);
    try std.testing.expectEqual(@as(i32, 12), surface.pending_offset_y);
    try commitSurfaceResource(client, 5);
    try std.testing.expect(compositor.currentBuffer(id) == null);
    try std.testing.expect(surface_registry.renderState(id) == null);
    try std.testing.expectEqual(@as(i32, 11), surface.current_offset_x);
    try std.testing.expectEqual(@as(i32, 12), surface.current_offset_y);
    try std.testing.expectEqual(next_source_version, surface.next_source_version);

    try setSurfaceOffset(client, 5, 13, 14);
    try commitSurfaceResource(client, 5);
    try std.testing.expect(compositor.currentBuffer(id) == null);
    try std.testing.expect(surface_registry.renderState(id) == null);
    try std.testing.expectEqual(@as(i32, 13), surface.current_offset_x);
    try std.testing.expectEqual(@as(i32, 14), surface.current_offset_y);
    try std.testing.expectEqual(next_source_version, surface.next_source_version);

    try setSurfaceOffset(client, 5, 20, 21);
    try attachBuffer(client, 5, 8);
    try attachBuffer(client, 5, 7);
    try std.testing.expectEqual(@as(i32, 20), surface.pending_offset_x);
    try std.testing.expectEqual(@as(i32, 21), surface.pending_offset_y);
    try send(client, 7, 0, &core.wl_buffer.request_messages[0], &.{});
    try std.testing.expect(surface.pending_attachment.?.resource == null);
    try std.testing.expectEqual(@as(i32, 20), surface.pending_offset_x);
    try std.testing.expectEqual(@as(i32, 21), surface.pending_offset_y);
    const destroyed_buffer = try drain(client);
    defer std.testing.allocator.free(destroyed_buffer);
    try expectDeleteIds(destroyed_buffer, &.{7});

    try attachBuffer(client, 5, 8);
    try std.testing.expectEqual(@as(i32, 20), surface.pending_offset_x);
    try std.testing.expectEqual(@as(i32, 21), surface.pending_offset_y);
    try setSurfaceOffset(client, 5, 30, 31);
    try setSurfaceOffset(client, 5, 32, 33);
    var replacement_prepared = PreparedCommit.init(surface);
    defer replacement_prepared.deinit();
    try std.testing.expectEqual(@as(i32, 32), replacement_prepared.offset_x);
    try std.testing.expectEqual(@as(i32, 33), replacement_prepared.offset_y);
    try commitSurfaceResource(client, 5);

    try std.testing.expectEqual(@as(i32, 0), surface.pending_offset_x);
    try std.testing.expectEqual(@as(i32, 0), surface.pending_offset_y);
    try std.testing.expectEqual(@as(i32, 32), surface.current_offset_x);
    try std.testing.expectEqual(@as(i32, 33), surface.current_offset_y);
    try std.testing.expectEqualSlices(u32, pixels[1..2], compositor.currentBuffer(id).?.pixels);
    try std.testing.expectEqual(next_source_version + 1, surface.next_source_version);
    const replacement_release = try drain(client);
    defer std.testing.allocator.free(replacement_release);
    try std.testing.expectEqual(@as(usize, 8), replacement_release.len);
    try std.testing.expectEqual(@as(u32, 8), word(replacement_release, 0));
    try std.testing.expect(client.fatal() == null);
}

test "scanner wl_surface version 5 and newer reject attach offsets before mutation" {
    const Case = struct {
        fn run(version: u32) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var surface_registry = SurfaceRegistry.init(std.testing.allocator);
            defer surface_registry.deinit();
            var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
            var compositor: WayringCompositor = undefined;
            try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
            defer compositor.deinit();
            listener_state.compositor = &compositor;
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }

            try bindCompositor(client, 3);
            try bindShm(&compositor, client, 4);
            try createSurfaceResource(client, 3, 5);
            const id = compositor.surfaceId(client, 5).?;
            const surface = compositor.surfaceForId(id).?;
            try compositor.replaceSurfaceResourceForTest(client, surface, version);
            const pixels = [_]u32{ 0xff11_2233, 0xff44_5566, 0xff77_8899 };
            const fd = try memfdWithPixels(&pixels);
            defer _ = std.c.close(fd);
            try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
            try createShmBuffer(client, 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
            try createShmBuffer(client, 6, 8, @sizeOf(u32), .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
            try createShmBuffer(client, 6, 9, 2 * @sizeOf(u32), .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);

            try attachBuffer(client, 5, 7);
            try commitSurfaceResource(client, 5);
            const first_release = try drain(client);
            defer std.testing.allocator.free(first_release);
            try std.testing.expectEqual(@as(usize, 8), first_release.len);
            try attachBuffer(client, 5, 8);
            try setSurfaceOffset(client, 5, -23, 29);
            try setBufferScale(client, 5, 2);
            try setBufferTransform(client, 5, @intCast(core.wl_output.transform.@"90"));
            try damageSurface(client, 5, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
            try requestFrame(client, 5, 10);

            const old_current_pointer = compositor.currentBuffer(id).?.pixels.ptr;
            const old_current_pixels = compositor.currentBuffer(id).?.pixels;
            const old_source_cache = surface_registry.renderState(id).?.buffer.source_cache.?;
            const old_source_version = surface.next_source_version;
            const old_committed_count = listener_state.committed_count;
            const old_event_count = listener_state.event_count;
            const old_pending_resource = surface.pending_attachment.?.resource;
            const old_pending_observer = surface.pending_attachment.?.observer;
            const old_pending_pin = surface.pending_attachment.?.pin.buffer;
            const old_callback = surface.frame_callbacks.items[0];

            try attachBufferAt(client, 5, 9, 1, -2);

            try std.testing.expectEqual(server.Fatal.Kind.protocol, client.fatal().?.kind);
            try std.testing.expectEqual(@as(?u32, @intCast(core.wl_surface.@"error".invalid_offset)), client.fatal().?.protocol_code);
            try std.testing.expectEqual(@as(u32, 5), client.fatal().?.object_id);
            try std.testing.expectEqual(version, surface.resource.version());
            try std.testing.expect(surface.has_pending_attachment);
            try std.testing.expectEqual(old_pending_resource, surface.pending_attachment.?.resource);
            try std.testing.expectEqual(old_pending_observer, surface.pending_attachment.?.observer);
            try std.testing.expectEqual(old_pending_pin, surface.pending_attachment.?.pin.buffer);
            try std.testing.expectEqual(@as(i32, -23), surface.pending_offset_x);
            try std.testing.expectEqual(@as(i32, 29), surface.pending_offset_y);
            try std.testing.expectEqual(@as(i32, 0), surface.current_offset_x);
            try std.testing.expectEqual(@as(i32, 0), surface.current_offset_y);
            try std.testing.expectEqual(@as(i32, 2), surface.pending_scale);
            try std.testing.expectEqual(@as(i32, 1), surface.current_scale);
            try std.testing.expectEqual(render.BufferTransform.rotate_90, surface.pending_transform);
            try std.testing.expectEqual(render.BufferTransform.normal, surface.current_transform);
            try std.testing.expect(surface.pending_damage.contains(0, 0));
            try std.testing.expectEqual(@as(usize, 1), surface.frame_callbacks.items.len);
            try std.testing.expectEqual(old_callback, surface.frame_callbacks.items[0]);
            try std.testing.expectEqual(FrameCallback.State.pending, old_callback.state);
            try std.testing.expectEqual(&old_callback.resource.runtime, client.lookup(10).?);
            try std.testing.expectEqual(old_current_pointer, compositor.currentBuffer(id).?.pixels.ptr);
            try std.testing.expectEqualSlices(u32, old_current_pixels, compositor.currentBuffer(id).?.pixels);
            try std.testing.expectEqual(old_source_cache, surface_registry.renderState(id).?.buffer.source_cache.?);
            try std.testing.expectEqual(old_source_version, surface.next_source_version);
            try std.testing.expectEqual(old_committed_count, listener_state.committed_count);
            try std.testing.expectEqual(old_event_count, listener_state.event_count);
            try std.testing.expectEqual(old_current_pointer, listener_state.last_pixel_pointer.?);
            try std.testing.expectEqual(old_source_cache, listener_state.last_source_cache.?);

            const terminal = try drain(client);
            defer std.testing.allocator.free(terminal);
            try std.testing.expect(terminal.len >= 8);
            try std.testing.expectEqual(@as(u32, 1), word(terminal, 0));

            const live_before_unused_destroy = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
            client.lookup(9).?.destroy();
            try std.testing.expectEqual(
                live_before_unused_destroy - @sizeOf(server.shm.Buffer),
                compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
            );
            try std.testing.expectEqual(old_pending_resource, surface.pending_attachment.?.resource);
        }
    };

    try Case.run(5);
    if (core.wl_surface.interface.version > 5) try Case.run(core.wl_surface.interface.version);
}

test "scanner-backed surface commits copied SHM and releases the buffer" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositorVersion(client, 3, 4);
    try send(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = compositor.shm.global.?.name() },
        .{ .new_id = .{ .generic = .{ .interface = "wl_shm", .version = 1, .id = 4 } } },
    });
    const formats = try drain(client);
    defer std.testing.allocator.free(formats);
    try send(client, 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    const surface_id = compositor.surfaceId(client, 5).?;
    const surface = compositor.findClient(client).?.surfaces.items[0];

    const pixels = [_]u32{ 0x0011_2233, 0x0044_5566 };
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try sendWithFds(client, 4, 0, &core.wl_shm.request_messages[0], &.{
        .{ .new_id = .{ .typed = 6 } }, .{ .fd = fd }, .{ .int = @intCast(@sizeOf(@TypeOf(pixels))) },
    });
    try send(client, 6, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = 7 } },
        .{ .int = 0 },
        .{ .int = 2 },
        .{ .int = 1 },
        .{ .int = 2 * @sizeOf(u32) },
        .{ .uint = @intFromEnum(server.shm.Format.xrgb8888) },
    });
    try send(client, 5, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = 7 }, .{ .int = 0 }, .{ .int = 0 },
    });
    try send(client, 5, 2, &core.wl_surface.request_messages[2], &.{
        .{ .int = 0 }, .{ .int = 0 }, .{ .int = 2 }, .{ .int = 1 },
    });
    try damageBuffer(client, 5, std.math.minInt(i32), -10, std.math.maxInt(i32), 1);
    try send(client, 5, 6, &core.wl_surface.request_messages[6], &.{});

    const current = compositor.currentBuffer(surface_id).?;
    try std.testing.expect(current.forceOpaque());
    try std.testing.expectEqualSlices(u32, &.{ 0xff11_2233, 0xff44_5566 }, current.pixels);
    const render_state = surface_registry.renderState(surface_id).?;
    try std.testing.expectEqual(current.pixels.ptr, render_state.buffer.pixels.ptr);
    try std.testing.expectEqualSlices(u32, current.pixels, render_state.buffer.pixels);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 1 }, render_state.buffer.size);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 1 }, render_state.logical_size);
    try std.testing.expectEqual(@as(u32, 2), render_state.buffer.stride_pixels);
    try std.testing.expectEqual(render.SourceCache{ .id = surface.source_cache_id, .version = 1 }, render_state.buffer.source_cache.?);
    try std.testing.expect(render_state.buffer.source_damage == null);
    try std.testing.expect(render_state.source == null);
    try std.testing.expectEqual(render.BufferTransform.normal, render_state.transform);
    try std.testing.expect(render_state.force_opaque);
    try std.testing.expectEqual(std.math.maxInt(u32), render_state.alpha_multiplier);
    try std.testing.expect(render_state.opaque_region.?.isEmpty());
    try std.testing.expect(render_state.blur_region == null);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);
    try std.testing.expectEqual(render.SourceCache{ .id = surface.source_cache_id, .version = 1 }, listener_state.last_source_cache.?);
    try std.testing.expectEqual(current.pixels.ptr, listener_state.last_pixel_pointer.?);
    const release = try drain(client);
    defer std.testing.allocator.free(release);
    try std.testing.expectEqual(@as(usize, 8), release.len);
    try std.testing.expectEqual(@as(u32, 7), word(release, 0));

    try send(client, 6, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = 8 } },
        .{ .int = 0 },
        .{ .int = 2 },
        .{ .int = 1 },
        .{ .int = 2 * @sizeOf(u32) },
        .{ .uint = @intFromEnum(server.shm.Format.argb8888) },
    });
    try send(client, 5, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = 8 }, .{ .int = 0 }, .{ .int = 0 },
    });
    try send(client, 8, 0, &core.wl_buffer.request_messages[0], &.{});
    const delete_id = try drain(client);
    defer std.testing.allocator.free(delete_id);
    try send(client, 5, 6, &core.wl_surface.request_messages[6], &.{});
    try std.testing.expectEqualSlices(u32, &pixels, compositor.currentBuffer(surface_id).?.pixels);
    const second_state = surface_registry.renderState(surface_id).?;
    try std.testing.expectEqual(render.SourceCache{ .id = surface.source_cache_id, .version = 2 }, second_state.buffer.source_cache.?);
    try std.testing.expect(!second_state.force_opaque);
    try std.testing.expectEqual(compositor.currentBuffer(surface_id).?.pixels.ptr, second_state.buffer.pixels.ptr);
    try std.testing.expectEqual(@as(usize, 2), listener_state.committed_count);
    const no_release = try drain(client);
    defer std.testing.allocator.free(no_release);
    try std.testing.expectEqual(@as(usize, 0), no_release.len);

    try send(client, 6, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = 8 } },
        .{ .int = 0 },
        .{ .int = 2 },
        .{ .int = 1 },
        .{ .int = 2 * @sizeOf(u32) },
        .{ .uint = @intFromEnum(server.shm.Format.argb8888) },
    });
    try send(client, 5, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = 8 }, .{ .int = 0 }, .{ .int = 0 },
    });
    if (std.os.linux.errno(std.os.linux.ftruncate(fd, 0)) != .SUCCESS) return error.Unexpected;
    try send(client, 5, 6, &core.wl_surface.request_messages[6], &.{});
    try std.testing.expectEqual(server.Fatal.Kind.implementation, client.fatal().?.kind);
    try std.testing.expectEqualSlices(u32, &pixels, compositor.currentBuffer(surface_id).?.pixels);
    try std.testing.expectEqual(render.SourceCache{ .id = surface.source_cache_id, .version = 2 }, surface_registry.renderState(surface_id).?.buffer.source_cache.?);
    try std.testing.expectEqual(@as(usize, 2), listener_state.committed_count);
}

test "listener observes published equal-size resize null and damage-only transactions" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try bindShm(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    const id = compositor.surfaceId(client, 5).?;
    const surface = compositor.surfaceForId(id).?;
    try std.testing.expectEqual(@as(usize, 1), listener_state.added_count);
    try std.testing.expect(surface_registry.renderState(id) == null);

    const pixels = [_]u32{
        0xff11_0001,
        0xff11_0002,
        0xff22_0001,
        0xff22_0002,
        0xff33_0001,
        0xff33_0002,
    };
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
    try createShmBuffer(client, 6, 7, 0, .{ .width = 2, .height = 1 }, 2 * @sizeOf(u32), .argb8888);
    try createShmBuffer(client, 6, 8, 2 * @sizeOf(u32), .{ .width = 2, .height = 1 }, 2 * @sizeOf(u32), .argb8888);
    try createShmBuffer(client, 6, 9, 4 * @sizeOf(u32), .{ .width = 1, .height = 2 }, @sizeOf(u32), .argb8888);

    try attachBuffer(client, 5, 7);
    try damageSurface(client, 5, .{ .x = 0, .y = 0, .width = 2, .height = 1 });
    try commitSurfaceResource(client, 5);
    const first_release = try drain(client);
    defer std.testing.allocator.free(first_release);
    try std.testing.expectEqual(@as(usize, 8), first_release.len);
    const first_pointer = listener_state.last_pixel_pointer.?;
    const source_id = listener_state.last_source_cache.?.id;
    try std.testing.expectEqual(render.SourceCache{ .id = source_id, .version = 1 }, listener_state.last_source_cache.?);
    try std.testing.expectEqual(@as(u32, pixels[0]), listener_state.last_first_pixel.?);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);

    try damageSurface(client, 5, .{ .x = 1, .y = 0, .width = 1, .height = 1 });
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(usize, 2), listener_state.committed_count);
    try std.testing.expectEqual(first_pointer, compositor.currentBuffer(id).?.pixels.ptr);
    try std.testing.expectEqual(@as(u64, 2), surface.next_source_version);

    try attachBuffer(client, 5, 8);
    try damageSurface(client, 5, .{ .x = 0, .y = 0, .width = 2, .height = 1 });
    try commitSurfaceResource(client, 5);
    const second_release = try drain(client);
    defer std.testing.allocator.free(second_release);
    try std.testing.expectEqual(@as(usize, 8), second_release.len);
    try std.testing.expectEqual(@as(usize, 3), listener_state.committed_count);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 1 }, listener_state.last_size.?);
    try std.testing.expectEqual(render.SourceCache{ .id = source_id, .version = 2 }, listener_state.last_source_cache.?);
    try std.testing.expectEqual(@as(u32, pixels[2]), listener_state.last_first_pixel.?);
    try std.testing.expect(first_pointer != listener_state.last_pixel_pointer.?);
    try std.testing.expect(surface_registry.renderState(id).?.buffer.source_damage == null);

    try attachBuffer(client, 5, 9);
    try commitSurfaceResource(client, 5);
    const third_release = try drain(client);
    defer std.testing.allocator.free(third_release);
    try std.testing.expectEqual(@as(usize, 8), third_release.len);
    try std.testing.expectEqual(@as(usize, 4), listener_state.committed_count);
    try std.testing.expectEqual(render.Size{ .width = 1, .height = 2 }, listener_state.last_size.?);
    try std.testing.expectEqual(render.SourceCache{ .id = source_id, .version = 3 }, listener_state.last_source_cache.?);
    try std.testing.expectEqualSlices(u32, pixels[4..6], surface_registry.renderState(id).?.buffer.pixels);

    try attachBuffer(client, 5, null);
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(usize, 5), listener_state.committed_count);
    try std.testing.expect(listener_state.last_size == null);
    try std.testing.expect(compositor.currentBuffer(id) == null);
    try std.testing.expect(surface_registry.renderState(id) == null);

    try damageSurface(client, 5, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(usize, 6), listener_state.committed_count);
    try std.testing.expectEqualSlices(
        TestPresentationListener.Event,
        &.{ .added, .committed, .committed, .committed, .committed, .committed, .committed },
        listener_state.events[0..listener_state.event_count],
    );
}

test "retained content rejects non-divisible transformed scale without publication" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositorVersion(client, 3, 3);
    try bindShm(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    const id = compositor.surfaceId(client, 5).?;
    const surface = compositor.surfaceForId(id).?;
    var pixels: [6 * 4]u32 = undefined;
    for (&pixels, 0..) |*pixel, index| pixel.* = 0xff55_0000 | @as(u32, @intCast(index));
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
    try createShmBuffer(client, 6, 7, 0, .{ .width = 6, .height = 4 }, 6 * @sizeOf(u32), .argb8888);
    try setBufferScale(client, 5, 2);
    try attachBuffer(client, 5, 7);
    try commitSurfaceResource(client, 5);
    const release = try drain(client);
    defer std.testing.allocator.free(release);

    const current_pointer = compositor.currentBuffer(id).?.pixels.ptr;
    const current_cache = surface_registry.renderState(id).?.buffer.source_cache.?;
    const listener_count = listener_state.committed_count;
    const listener_events = listener_state.event_count;
    try setBufferScale(client, 5, 3);
    try setBufferTransform(client, 5, @intCast(core.wl_output.transform.@"90"));
    try damageSurface(client, 5, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    try requestFrame(client, 5, 8);
    try commitSurfaceResource(client, 5);

    const fatal = client.fatal().?;
    try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
    try std.testing.expectEqual(
        @as(?u32, @intCast(core.wl_surface.@"error".invalid_size)),
        fatal.protocol_code,
    );
    try std.testing.expectEqual(@as(u32, 5), fatal.object_id);
    try std.testing.expectEqual(@as(i32, 3), surface.pending_scale);
    try std.testing.expectEqual(@as(i32, 2), surface.current_scale);
    try std.testing.expectEqual(render.BufferTransform.rotate_90, surface.pending_transform);
    try std.testing.expectEqual(render.BufferTransform.normal, surface.current_transform);
    try std.testing.expectEqual(render.Size{ .width = 3, .height = 2 }, surface.current_logical_size.?);
    try std.testing.expect(surface.pending_damage.contains(0, 0));
    try std.testing.expectEqual(current_pointer, compositor.currentBuffer(id).?.pixels.ptr);
    try std.testing.expectEqualSlices(u32, &pixels, compositor.currentBuffer(id).?.pixels);
    const current_state = surface_registry.renderState(id).?;
    try std.testing.expectEqual(render.BufferTransform.normal, current_state.transform);
    try std.testing.expectEqual(render.Size{ .width = 3, .height = 2 }, current_state.logical_size);
    try std.testing.expectEqual(current_cache, current_state.buffer.source_cache.?);
    try std.testing.expectEqual(@as(u64, 2), surface.next_source_version);
    try std.testing.expectEqual(listener_count, listener_state.committed_count);
    try std.testing.expectEqual(listener_events, listener_state.event_count);
    try std.testing.expectEqual(current_pointer, listener_state.last_pixel_pointer.?);
    try std.testing.expectEqual(current_cache, listener_state.last_source_cache.?);
    try std.testing.expectEqual(@as(usize, 1), surface.frame_callbacks.items.len);
    try std.testing.expectEqual(FrameCallback.State.pending, surface.frame_callbacks.items[0].state);
    try std.testing.expect(!surface.has_pending_attachment);
    try std.testing.expect(surface.pending_attachment == null);
}

test "new attachment invalid size preserves current state and consumes only terminal pin" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositorVersion(client, 3, 3);
    try bindShm(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    const id = compositor.surfaceId(client, 5).?;
    const surface = compositor.surfaceForId(id).?;
    var pixels: [8 + 6]u32 = undefined;
    for (&pixels, 0..) |*pixel, index| pixel.* = 0xff77_0000 | @as(u32, @intCast(index));
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
    try createShmBuffer(client, 6, 7, 0, .{ .width = 4, .height = 2 }, 4 * @sizeOf(u32), .argb8888);
    try createShmBuffer(client, 6, 8, 8 * @sizeOf(u32), .{ .width = 3, .height = 2 }, 3 * @sizeOf(u32), .argb8888);
    try setBufferScale(client, 5, 2);
    try attachBuffer(client, 5, 7);
    try commitSurfaceResource(client, 5);
    const first_release = try drain(client);
    defer std.testing.allocator.free(first_release);

    const current_pointer = compositor.currentBuffer(id).?.pixels.ptr;
    const current_cache = surface_registry.renderState(id).?.buffer.source_cache.?;
    const listener_count = listener_state.committed_count;
    const listener_events = listener_state.event_count;
    try setBufferTransform(client, 5, @intCast(core.wl_output.transform.@"90"));
    try requestFrame(client, 5, 9);
    const live_before_attachment = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    const candidate_resource = client.lookup(8).?;
    try attachBuffer(client, 5, 8);
    try std.testing.expect(surface.has_pending_attachment);
    try std.testing.expect(surface.pending_attachment.?.observer != null);
    try std.testing.expect(surface.pending_attachment.?.pin.buffer != null);
    try commitSurfaceResource(client, 5);

    const fatal = client.fatal().?;
    try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
    try std.testing.expectEqual(
        @as(?u32, @intCast(core.wl_surface.@"error".invalid_size)),
        fatal.protocol_code,
    );
    try std.testing.expectEqual(@as(u32, 5), fatal.object_id);
    try std.testing.expect(!surface.has_pending_attachment);
    try std.testing.expect(surface.pending_attachment == null);
    try std.testing.expectEqual(@as(i32, 0), surface.pending_offset_x);
    try std.testing.expectEqual(@as(i32, 0), surface.pending_offset_y);
    try std.testing.expectEqual(
        live_before_attachment,
        compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
    );
    try std.testing.expectEqual(@as(i32, 2), surface.pending_scale);
    try std.testing.expectEqual(@as(i32, 2), surface.current_scale);
    try std.testing.expectEqual(render.BufferTransform.rotate_90, surface.pending_transform);
    try std.testing.expectEqual(render.BufferTransform.normal, surface.current_transform);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 1 }, surface.current_logical_size.?);
    try std.testing.expectEqual(current_pointer, compositor.currentBuffer(id).?.pixels.ptr);
    try std.testing.expectEqualSlices(u32, pixels[0..8], compositor.currentBuffer(id).?.pixels);
    const current_state = surface_registry.renderState(id).?;
    try std.testing.expectEqual(render.BufferTransform.normal, current_state.transform);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 1 }, current_state.logical_size);
    try std.testing.expectEqual(current_cache, current_state.buffer.source_cache.?);
    try std.testing.expectEqual(@as(u64, 2), surface.next_source_version);
    try std.testing.expectEqual(listener_count, listener_state.committed_count);
    try std.testing.expectEqual(listener_events, listener_state.event_count);
    try std.testing.expectEqual(current_pointer, listener_state.last_pixel_pointer.?);
    try std.testing.expectEqual(current_cache, listener_state.last_source_cache.?);
    try std.testing.expectEqual(@as(usize, 1), surface.frame_callbacks.items.len);
    try std.testing.expectEqual(FrameCallback.State.pending, surface.frame_callbacks.items[0].state);

    const terminal = try drain(client);
    defer std.testing.allocator.free(terminal);
    try std.testing.expect(terminal.len >= 8);
    try std.testing.expectEqual(@as(u32, 1), word(terminal, 0));

    const live_before_buffer_destroy = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    candidate_resource.destroy();
    try std.testing.expectEqual(
        live_before_buffer_destroy - @sizeOf(server.shm.Buffer),
        compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
    );
    try std.testing.expectEqual(current_pointer, compositor.currentBuffer(id).?.pixels.ptr);
}

test "prepared commit failures preserve all published surface state and reclaim candidates" {
    const Case = struct {
        fn run(fault: CommitFault) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var surface_registry = SurfaceRegistry.init(std.testing.allocator);
            defer surface_registry.deinit();
            var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
            var compositor: WayringCompositor = undefined;
            try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
            defer compositor.deinit();
            listener_state.compositor = &compositor;
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }

            try bindCompositorVersion(client, 3, 5);
            try bindShm(&compositor, client, 4);
            try createSurfaceResource(client, 3, 5);
            const id = compositor.surfaceId(client, 5).?;
            const surface = compositor.surfaceForId(id).?;
            const pixels = [_]u32{
                0xff11_2233,
                0xff44_5566,
                0xffaa_bbcc,
                0xffdd_eeff,
                0xff10_2030,
                0xff40_5060,
                0xff70_8090,
                0xffa0_b0c0,
            };
            const fd = try memfdWithPixels(&pixels);
            defer _ = std.c.close(fd);
            try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
            try createShmBuffer(client, 6, 7, 0, .{ .width = 2, .height = 2 }, 2 * @sizeOf(u32), .argb8888);
            try createShmBuffer(client, 6, 8, 4 * @sizeOf(u32), .{ .width = 2, .height = 2 }, 2 * @sizeOf(u32), .argb8888);
            try createRegionResource(client, 3, 9);
            try createRegionResource(client, 3, 10);
            try addRegion(client, 9, 0, 0, 1, 1);
            try addRegion(client, 10, 8, 8, 1, 1);

            try setSurfaceRegion(client, 5, 4, 9);
            try setSurfaceRegion(client, 5, 5, 9);
            try setBufferScale(client, 5, 2);
            try setBufferTransform(client, 5, @intCast(core.wl_output.transform.@"90"));
            try attachBuffer(client, 5, 7);
            try commitSurfaceResource(client, 5);
            const first_release = try drain(client);
            defer std.testing.allocator.free(first_release);
            try std.testing.expectEqual(@as(usize, 8), first_release.len);

            const old_pointer = compositor.currentBuffer(id).?.pixels.ptr;
            const old_source_cache = surface_registry.renderState(id).?.buffer.source_cache.?;
            const old_version = surface.next_source_version;
            const old_listener_count = listener_state.committed_count;
            const old_callbacks_committed_count = listener_state.callbacks_committed_count;
            try std.testing.expect(surface.current_opaque.contains(0, 0));
            try std.testing.expect(!surface.current_opaque.contains(8, 8));
            try std.testing.expect(!surface.current_input.infinite);
            try std.testing.expect(surface.current_input.value.contains(0, 0));

            try requestFrame(client, 5, 11);
            try std.testing.expectEqual(@as(usize, 1), surface.frame_callbacks.items.len);
            try std.testing.expectEqual(FrameCallback.State.pending, surface.frame_callbacks.items[0].state);
            try setSurfaceRegion(client, 5, 4, 10);
            try setSurfaceRegion(client, 5, 5, 10);
            try damageSurface(client, 5, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
            try setBufferScale(client, 5, 1);
            try setBufferTransform(client, 5, @intCast(core.wl_output.transform.normal));
            const live_before_attachment = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
            try setSurfaceOffset(client, 5, -4, 5);
            try attachBuffer(client, 5, 8);
            try std.testing.expect(surface.pending_attachment.?.observer != null);
            compositor.commit_fault = fault;
            try commitSurfaceResource(client, 5);

            const expected_fatal: server.Fatal.Kind = switch (fault) {
                .access, .access_end => .implementation,
                else => .out_of_memory,
            };
            try std.testing.expectEqual(expected_fatal, client.fatal().?.kind);
            try std.testing.expect(surface.pending_attachment == null);
            try std.testing.expect(!surface.has_pending_attachment);
            try std.testing.expectEqual(@as(i32, -4), surface.pending_offset_x);
            try std.testing.expectEqual(@as(i32, 5), surface.pending_offset_y);
            try std.testing.expectEqual(@as(i32, 0), surface.current_offset_x);
            try std.testing.expectEqual(@as(i32, 0), surface.current_offset_y);
            try std.testing.expectEqual(
                live_before_attachment,
                compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
            );
            try std.testing.expectEqual(old_pointer, compositor.currentBuffer(id).?.pixels.ptr);
            try std.testing.expectEqualSlices(u32, pixels[0..4], compositor.currentBuffer(id).?.pixels);
            try std.testing.expectEqual(old_source_cache, surface_registry.renderState(id).?.buffer.source_cache.?);
            try std.testing.expect(surface_registry.renderState(id).?.buffer.source_damage == null);
            try std.testing.expectEqual(render.BufferTransform.rotate_90, surface_registry.renderState(id).?.transform);
            try std.testing.expectEqual(old_version, surface.next_source_version);
            try std.testing.expectEqual(old_listener_count, listener_state.committed_count);
            try std.testing.expectEqual(old_callbacks_committed_count, listener_state.callbacks_committed_count);
            try std.testing.expectEqual(@as(usize, 0), surface.content_updates.items.len);
            try std.testing.expectEqual(@as(usize, 1), surface.frame_callbacks.items.len);
            try std.testing.expectEqual(FrameCallback.State.pending, surface.frame_callbacks.items[0].state);
            try std.testing.expectEqual(&surface.frame_callbacks.items[0].resource.runtime, client.lookup(11).?);
            const completion = listener_state.frame_completion.?;
            completion.complete(completion.context, id, 7);
            try std.testing.expectEqual(FrameCallback.State.pending, surface.frame_callbacks.items[0].state);
            try std.testing.expect(surface.current_opaque.contains(0, 0));
            try std.testing.expect(!surface.current_opaque.contains(8, 8));
            try std.testing.expect(!surface.current_input.infinite);
            try std.testing.expect(surface.current_input.value.contains(0, 0));
            try std.testing.expect(!surface.current_input.value.contains(8, 8));
            try std.testing.expectEqual(@as(i32, 1), surface.pending_scale);
            try std.testing.expectEqual(render.BufferTransform.normal, surface.pending_transform);
            try std.testing.expectEqual(render.Size{ .width = 1, .height = 1 }, surface.current_logical_size.?);
            try std.testing.expectEqual(@as(i32, 2), surface.current_scale);
            try std.testing.expectEqual(render.BufferTransform.rotate_90, surface.current_transform);
            const terminal = try drain(client);
            defer std.testing.allocator.free(terminal);
            try std.testing.expect(terminal.len >= 8);
            try std.testing.expectEqual(@as(u32, 1), word(terminal, 0));
        }
    };

    for ([_]CommitFault{
        .queue_storage,
        .candidate_allocation,
        .prepared_owned,
        .region_copy,
        .claims,
        .topology_snapshot,
        .apply_scratch,
        .batch_assembly,
        .access,
        .copy,
        .access_end,
        .release_enqueue,
    }) |fault| try Case.run(fault);
}

test "scanner-backed release failure cleans pending attachment and preserves current pixels" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    var client_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const managed = try server.CoreClient.create(client_allocator.allocator(), &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try send(client, 2, 0, &core.wl_registry.request_messages[0], &.{
        .{ .uint = compositor.shm.global.?.name() },
        .{ .new_id = .{ .generic = .{ .interface = "wl_shm", .version = 1, .id = 4 } } },
    });
    const formats = try drain(client);
    defer std.testing.allocator.free(formats);
    try send(client, 3, 0, &core.wl_compositor.request_messages[0], &.{.{ .new_id = .{ .typed = 5 } }});
    const surface_id = compositor.surfaceId(client, 5).?;
    const surface = compositor.findClient(client).?.surfaces.items[0];

    const pixels = [_]u32{
        0xff11_2233,
        0xff44_5566,
        0xffaa_bbcc,
        0xffdd_eeff,
    };
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try sendWithFds(client, 4, 0, &core.wl_shm.request_messages[0], &.{
        .{ .new_id = .{ .typed = 6 } }, .{ .fd = fd }, .{ .int = @intCast(@sizeOf(@TypeOf(pixels))) },
    });
    try send(client, 6, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = 7 } },
        .{ .int = 0 },
        .{ .int = 2 },
        .{ .int = 1 },
        .{ .int = 2 * @sizeOf(u32) },
        .{ .uint = @intFromEnum(server.shm.Format.argb8888) },
    });
    try send(client, 6, 0, &core.wl_shm_pool.request_messages[0], &.{
        .{ .new_id = .{ .typed = 8 } },
        .{ .int = 2 * @sizeOf(u32) },
        .{ .int = 2 },
        .{ .int = 1 },
        .{ .int = 2 * @sizeOf(u32) },
        .{ .uint = @intFromEnum(server.shm.Format.argb8888) },
    });
    try send(client, 5, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = 7 }, .{ .int = 0 }, .{ .int = 0 },
    });
    try send(client, 5, 6, &core.wl_surface.request_messages[6], &.{});
    const first_release = try drain(client);
    defer std.testing.allocator.free(first_release);
    const old_current = compositor.currentBuffer(surface_id).?;
    const old_pixels = old_current.pixels.ptr;
    const old_version = surface.next_source_version;
    try std.testing.expectEqualSlices(u32, pixels[0..2], old_current.pixels);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);

    const live_before_attachment = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    const candidate_resource = client.lookup(8).?;
    try send(client, 5, 1, &core.wl_surface.request_messages[1], &.{
        .{ .object = 8 }, .{ .int = 0 }, .{ .int = 0 },
    });
    try std.testing.expect(surface.has_pending_attachment);
    try std.testing.expect(surface.pending_attachment.?.observer != null);
    try std.testing.expect(compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes > live_before_attachment);

    const commit = try encode(5, 6, &core.wl_surface.request_messages[6], &.{});
    defer std.testing.allocator.free(commit);
    try client.receive(commit, &.{});
    client_allocator.fail_index = client_allocator.alloc_index;
    try client.dispatch();

    try std.testing.expect(client_allocator.has_induced_failure);
    try std.testing.expectEqual(server.Fatal.Kind.implementation, client.fatal().?.kind);
    try std.testing.expect(!surface.has_pending_attachment);
    try std.testing.expect(surface.pending_attachment == null);
    try std.testing.expectEqual(live_before_attachment, compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes);
    const preserved = compositor.currentBuffer(surface_id).?;
    try std.testing.expectEqual(old_pixels, preserved.pixels.ptr);
    try std.testing.expectEqualSlices(u32, pixels[0..2], preserved.pixels);
    try std.testing.expectEqual(old_version, surface.next_source_version);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);

    const live_before_buffer_destroy = compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes;
    candidate_resource.destroy();
    try std.testing.expectEqual(
        live_before_buffer_destroy - @sizeOf(server.shm.Buffer),
        compositor_allocator.allocated_bytes - compositor_allocator.freed_bytes,
    );
    try std.testing.expect(surface.pending_attachment == null);
    try std.testing.expectEqualSlices(u32, pixels[0..2], compositor.currentBuffer(surface_id).?.pixels);
}

test "copied snapshot OOM preserves published current and suppresses committed" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var compositor_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(compositor_allocator.allocator(), &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try bindShm(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    const id = compositor.surfaceId(client, 5).?;
    const surface = compositor.surfaceForId(id).?;
    const pixels = [_]u32{ 0xff11_2233, 0xff44_5566 };
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try createShmPool(client, 4, 6, fd, @sizeOf(@TypeOf(pixels)));
    try createShmBuffer(client, 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
    try createShmBuffer(client, 6, 8, @sizeOf(u32), .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);

    try attachBuffer(client, 5, 7);
    try commitSurfaceResource(client, 5);
    const first_release = try drain(client);
    defer std.testing.allocator.free(first_release);
    const old_pointer = compositor.currentBuffer(id).?.pixels.ptr;
    const old_source_cache = surface_registry.renderState(id).?.buffer.source_cache.?;
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);

    try attachBuffer(client, 5, 8);
    try std.testing.expect(surface.pending_attachment != null);
    compositor_allocator.fail_index = compositor_allocator.alloc_index;
    try commitSurfaceResource(client, 5);

    try std.testing.expect(compositor_allocator.has_induced_failure);
    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expect(surface.pending_attachment == null);
    try std.testing.expect(!surface.has_pending_attachment);
    try std.testing.expectEqual(old_pointer, compositor.currentBuffer(id).?.pixels.ptr);
    try std.testing.expectEqual(old_source_cache, surface_registry.renderState(id).?.buffer.source_cache.?);
    try std.testing.expectEqual(@as(u64, 2), surface.next_source_version);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);
}

test "explicit destroy and client disconnect remove listeners once while providers resolve" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &surface_registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const first = try server.CoreClient.create(std.testing.allocator, &host, .{});
    var first_live = true;
    defer if (first_live) {
        compositor.destroyClientResources(first.client());
        first.destroy();
    };
    const second = try server.CoreClient.create(std.testing.allocator, &host, .{});
    var second_live = true;
    defer if (second_live) {
        compositor.destroyClientResources(second.client());
        second.destroy();
    };

    try bindCompositor(first.client(), 3);
    try bindShm(&compositor, first.client(), 4);
    try createSurfaceResource(first.client(), 3, 5);
    const first_id = compositor.surfaceId(first.client(), 5).?;
    const first_pixels = [_]u32{0xff11_2233};
    const first_fd = try memfdWithPixels(&first_pixels);
    defer _ = std.c.close(first_fd);
    try createShmPool(first.client(), 4, 6, first_fd, @sizeOf(@TypeOf(first_pixels)));
    try createShmBuffer(first.client(), 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
    try attachBuffer(first.client(), 5, 7);
    try commitSurfaceResource(first.client(), 5);
    const first_release = try drain(first.client());
    defer std.testing.allocator.free(first_release);

    try bindCompositor(second.client(), 3);
    try bindShm(&compositor, second.client(), 4);
    try createSurfaceResource(second.client(), 3, 5);
    const second_id = compositor.surfaceId(second.client(), 5).?;
    const second_pixels = [_]u32{0xff44_5566};
    const second_fd = try memfdWithPixels(&second_pixels);
    defer _ = std.c.close(second_fd);
    try createShmPool(second.client(), 4, 6, second_fd, @sizeOf(@TypeOf(second_pixels)));
    try createShmBuffer(second.client(), 6, 7, 0, .{ .width = 1, .height = 1 }, @sizeOf(u32), .argb8888);
    try attachBuffer(second.client(), 5, 7);
    try commitSurfaceResource(second.client(), 5);
    const second_release = try drain(second.client());
    defer std.testing.allocator.free(second_release);

    try send(first.client(), 5, 0, &core.wl_surface.request_messages[0], &.{});
    try std.testing.expectEqual(@as(usize, 1), listener_state.removing_count);
    try std.testing.expect(listener_state.removing_had_render_state);
    try std.testing.expect(!surface_registry.contains(first_id));
    try std.testing.expect(!compositor.containsSurface(first_id));
    try std.testing.expect(surface_registry.contains(second_id));

    compositor.destroyClientResources(second.client());
    second.destroy();
    second_live = false;
    try std.testing.expectEqual(@as(usize, 2), listener_state.removing_count);
    try std.testing.expect(listener_state.removing_had_render_state);
    try std.testing.expect(!surface_registry.contains(second_id));
    try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());

    compositor.destroyClientResources(first.client());
    first.destroy();
    first_live = false;
    try std.testing.expectEqual(@as(usize, 2), listener_state.removing_count);
    try std.testing.expectEqualSlices(
        TestPresentationListener.Event,
        &.{ .added, .committed, .added, .committed, .removing, .removing },
        listener_state.events[0..listener_state.event_count],
    );
}

test "null listener teardown leaves unrelated registry provider for compositor deinit" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var synthetic: SyntheticRegistryProvider = .{ .pixel = 0xffaa_bbcc };
    const synthetic_id = try surface_registry.add(synthetic.provider());
    var synthetic_live = true;
    defer if (synthetic_live) surface_registry.remove(synthetic_id);
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, null);
    var compositor_live = true;
    defer if (compositor_live) compositor.deinit();
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    var client_live = true;
    defer if (client_live) {
        compositor.destroyClientResources(managed.client());
        managed.destroy();
    };

    try bindCompositor(managed.client(), 3);
    try createSurfaceResource(managed.client(), 3, 4);
    const id = compositor.surfaceId(managed.client(), 4).?;
    try std.testing.expect(surface_registry.contains(id));
    try std.testing.expectEqual(@as(usize, 2), surface_registry.len());

    compositor.destroyClientResources(managed.client());
    managed.destroy();
    client_live = false;
    try std.testing.expect(!surface_registry.contains(id));
    try std.testing.expect(surface_registry.contains(synthetic_id));
    try std.testing.expectEqual(@as(usize, 1), surface_registry.len());

    compositor.deinit();
    compositor_live = false;
    try std.testing.expect(surface_registry.contains(synthetic_id));
    try std.testing.expectEqual(@as(u32, synthetic.pixel), surface_registry.renderState(synthetic_id).?.buffer.pixels[0]);
    surface_registry.remove(synthetic_id);
    synthetic_live = false;
}

test "production globals publish v6 compositor v1 shm then v1 subcompositor and unpublish in reverse" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var surface_registry = SurfaceRegistry.init(std.testing.allocator);
    defer surface_registry.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &surface_registry, null);
    const compositor_global = compositor.global;
    const shm_global = compositor.shm.global.?;
    const subcompositor_global = compositor.subcompositor_global;

    const expected = [_]struct { name: []const u8, version: u32 }{
        .{ .name = "wl_compositor", .version = 6 },
        .{ .name = "wl_shm", .version = 1 },
        .{ .name = "wl_subcompositor", .version = 1 },
    };
    var globals = host.iterator();
    for (expected) |entry| {
        const global = globals.next().?;
        try std.testing.expectEqualStrings(entry.name, global.interface().name);
        try std.testing.expectEqual(entry.version, global.version());
    }
    try std.testing.expect(globals.next() == null);

    const RemovalLog = struct {
        items: [3]*const server.Server.Global = undefined,
        count: usize = 0,

        fn notify(
            self: *@This(),
            publication: server.Server.Publication,
            global: *const server.Server.Global,
        ) void {
            if (publication != .removed) return;
            std.debug.assert(self.count < self.items.len);
            self.items[self.count] = global;
            self.count += 1;
        }
    };
    var removal_log: RemovalLog = .{};
    _ = try host.addPublicationObserver(RemovalLog, &removal_log, RemovalLog.notify);
    compositor.deinit();
    try std.testing.expectEqual(@as(usize, 3), removal_log.count);
    try std.testing.expectEqual(subcompositor_global, removal_log.items[0]);
    try std.testing.expectEqual(shm_global, removal_log.items[1]);
    try std.testing.expectEqual(compositor_global, removal_log.items[2]);
}

test "global publication OOM rolls back every previously published global" {
    var measuring = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var measuring_host: server.Server = .init(measuring.allocator());
    var measuring_registry = SurfaceRegistry.init(std.testing.allocator);
    var measuring_compositor: WayringCompositor = undefined;
    try measuring_compositor.init(
        std.testing.allocator,
        &measuring_host,
        &measuring_registry,
        null,
    );
    const allocation_count = measuring.alloc_index;
    measuring_compositor.deinit();
    measuring_registry.deinit();
    measuring_host.deinit();
    try std.testing.expectEqual(measuring.allocated_bytes, measuring.freed_bytes);

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        failing.fail_index = fail_index;
        var host: server.Server = .init(failing.allocator());
        var surface_registry = SurfaceRegistry.init(std.testing.allocator);
        var compositor: WayringCompositor = undefined;
        try std.testing.expectError(
            error.OutOfMemory,
            compositor.init(std.testing.allocator, &host, &surface_registry, null),
        );
        try std.testing.expect(failing.has_induced_failure);
        var globals = host.iterator();
        try std.testing.expect(globals.next() == null);
        surface_registry.deinit();
        host.deinit();
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "generated wl_subcompositor and wl_subsurface scanner descriptors are exact" {
    try std.testing.expectEqualStrings("wl_subcompositor", core.wl_subcompositor.interface.name);
    try std.testing.expectEqual(@as(u32, 1), core.wl_subcompositor.interface.version);
    try std.testing.expectEqualStrings("wl_subsurface", core.wl_subsurface.interface.name);
    try std.testing.expectEqual(@as(u32, 1), core.wl_subsurface.interface.version);
    try std.testing.expectEqual(@as(usize, 2), core.wl_subcompositor.request_messages.len);
    try std.testing.expectEqualStrings("destroy", core.wl_subcompositor.request_messages[0].name);
    try std.testing.expect(core.wl_subcompositor.request_messages[0].destructor);
    try std.testing.expectEqualStrings("get_subsurface", core.wl_subcompositor.request_messages[1].name);
    try std.testing.expect(!core.wl_subcompositor.request_messages[1].destructor);
    try std.testing.expectEqual(@as(usize, 3), core.wl_subcompositor.request_messages[1].arguments.len);
    const get_arguments = core.wl_subcompositor.request_messages[1].arguments;
    try std.testing.expectEqualStrings("id", get_arguments[0].name);
    try std.testing.expectEqual(&core.wl_subsurface.interface, get_arguments[0].kind.new_id.?);
    try std.testing.expectEqualStrings("surface", get_arguments[1].name);
    try std.testing.expectEqual(&core.wl_surface.interface, get_arguments[1].kind.object.interface.?);
    try std.testing.expectEqual(wire.Nullability.required, get_arguments[1].kind.object.nullability);
    try std.testing.expectEqualStrings("parent", get_arguments[2].name);
    try std.testing.expectEqual(&core.wl_surface.interface, get_arguments[2].kind.object.interface.?);
    try std.testing.expectEqual(wire.Nullability.required, get_arguments[2].kind.object.nullability);
    try std.testing.expectEqual(@as(i64, 0), core.wl_subcompositor.@"error".bad_surface);
    try std.testing.expectEqual(@as(i64, 1), core.wl_subcompositor.@"error".bad_parent);
    const names = [_][]const u8{ "destroy", "set_position", "place_above", "place_below", "set_sync", "set_desync" };
    try std.testing.expectEqual(names.len, core.wl_subsurface.request_messages.len);
    for (names, 0..) |name, opcode| {
        try std.testing.expectEqualStrings(name, core.wl_subsurface.request_messages[opcode].name);
        try std.testing.expectEqual(opcode == 0, core.wl_subsurface.request_messages[opcode].destructor);
        try std.testing.expectEqual(@as(u32, 1), core.wl_subsurface.request_messages[opcode].since);
    }
    try std.testing.expectEqualStrings("x", core.wl_subsurface.request_messages[1].arguments[0].name);
    try std.testing.expectEqual(wire.ArgumentKind.int, core.wl_subsurface.request_messages[1].arguments[0].kind);
    try std.testing.expectEqualStrings("y", core.wl_subsurface.request_messages[1].arguments[1].name);
    try std.testing.expectEqual(wire.ArgumentKind.int, core.wl_subsurface.request_messages[1].arguments[1].kind);
    for (2..4) |opcode| {
        const argument = core.wl_subsurface.request_messages[opcode].arguments[0];
        try std.testing.expectEqualStrings("sibling", argument.name);
        try std.testing.expectEqual(&core.wl_surface.interface, argument.kind.object.interface.?);
        try std.testing.expectEqual(wire.Nullability.required, argument.kind.object.nullability);
    }
    try std.testing.expectEqual(@as(usize, 0), core.wl_subsurface.request_messages[4].arguments.len);
    try std.testing.expectEqual(@as(usize, 0), core.wl_subsurface.request_messages[5].arguments.len);
    try std.testing.expectEqual(@as(i64, 0), core.wl_subsurface.@"error".bad_surface);
}

test "scanner dispatch instantiates every wl_subcompositor and wl_subsurface handler" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, null);
    defer compositor.deinit();
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    // Publishing precedes get_registry because registry globals are a snapshot.
    try bindCompositor(client, 3);
    try bindTestSubcompositor(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    try createSurfaceResource(client, 3, 6);
    try getSubsurface(client, 4, 7, 5, 6);
    const child = compositor.surfaceForId(compositor.surfaceId(client, 5).?).?;
    try std.testing.expectEqual(Surface.Role.subsurface, child.role);
    try std.testing.expect(child.active_subsurface != null);
    try std.testing.expect(child.relationship.?.local_sync);
    try std.testing.expectEqual(Position{}, child.relationship.?.position);
    try std.testing.expectEqual(@as(u32, 1), child.active_subsurface.?.resource.version());
    try std.testing.expectEqual(&child.active_subsurface.?.resource.runtime, client.lookup(7).?);
    try std.testing.expectEqual(@as(usize, 1), compositor.findClient(client).?.subcompositors.items.len);
    try std.testing.expectEqual(@as(u32, 1), compositor.findClient(client).?.subcompositors.items[0].resource.version());

    try setSubsurfacePosition(client, 7, -12, 34);
    try std.testing.expectEqual(Position{ .x = -12, .y = 34 }, child.relationship.?.position);
    try placeSubsurface(client, 7, 6, true);
    try placeSubsurface(client, 7, 6, false);
    try setSubsurfaceMode(client, 7, false);
    try std.testing.expect(!child.relationship.?.local_sync);
    try setSubsurfaceMode(client, 7, true);
    try std.testing.expect(child.relationship.?.local_sync);
    const generation = child.relationship.?.identity.generation;
    try destroySubsurfaceResource(client, 7);
    try std.testing.expect(client.lookup(7) == null);
    try std.testing.expectEqual(Surface.Role.subsurface, child.role);
    try std.testing.expect(child.relationship == null);

    try getSubsurface(client, 4, 8, 5, 6);
    try std.testing.expect(child.relationship.?.identity.generation > generation);
    try destroySubsurfaceResource(client, 8);
    try send(client, 4, 0, &core.wl_subcompositor.request_messages[0], &.{});
    try std.testing.expect(client.lookup(4) == null);
    try std.testing.expect(client.fatal() == null);
}

test "scanner subsurface association and movement are parent double buffered" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositorVersion(client, 3, 6);
    try bindTestSubcompositor(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    try createSurfaceResource(client, 3, 6);
    const preferences = try drain(client);
    defer std.testing.allocator.free(preferences);
    try std.testing.expectEqual(@as(usize, 48), preferences.len);
    const parent_id = compositor.surfaceId(client, 5).?;
    const child_id = compositor.surfaceId(client, 6).?;
    const parent = compositor.surfaceForId(parent_id).?;
    const child = compositor.surfaceForId(child_id).?;

    try getSubsurface(client, 4, 7, 6, 5);
    try std.testing.expectEqual(@as(usize, 1), listener_state.detached_count);
    try std.testing.expectEqual(Surface.Role.subsurface, child.role);
    try std.testing.expect(child.active_subsurface != null);
    try std.testing.expect(child.relationship.?.local_sync);
    try std.testing.expectEqual(Position{}, child.relationship.?.position);
    try expectPendingChildren(parent, &.{child_id}, 0);
    try std.testing.expectEqual(@as(usize, 0), listener_state.committed_count);

    try setSubsurfacePosition(client, 7, 19, -3);
    try setSubsurfacePosition(client, 7, -8, 11);
    try std.testing.expectEqual(Position{ .x = -8, .y = 11 }, child.relationship.?.position);
    try std.testing.expectEqual(Position{ .x = -8, .y = 11 }, parent.children.items[0].position);
    try std.testing.expectEqual(@as(usize, 0), listener_state.committed_count);
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);
    try std.testing.expectEqual(@as(usize, 1), listener_state.last_batch_parent_count);
    try std.testing.expectEqual(@as(usize, 2), listener_state.last_parent_stack_lengths[0]);
    try std.testing.expectEqual(@as(usize, 1), listener_state.last_stack_child_count);
    try std.testing.expectEqual(child_id, listener_state.last_stack_child_ids[0]);
    try std.testing.expectEqual(Position{ .x = -8, .y = 11 }, listener_state.last_stack_child_positions[0]);
    try std.testing.expect(!child.relationship.?.detached);

    // wl_surface.offset remains ordinary consumed CU state, but never changes
    // the parent-pending subsurface placement.
    try setSurfaceOffset(client, 6, 71, -29);
    try commitSurfaceResource(client, 6);
    try std.testing.expectEqual(@as(i32, 0), child.pending_offset_x);
    try std.testing.expectEqual(@as(i32, 0), child.pending_offset_y);
    try std.testing.expectEqual(@as(i32, 0), child.current_offset_x);
    try std.testing.expectEqual(@as(i32, 0), child.current_offset_y);
    try std.testing.expectEqual(@as(usize, 1), child.content_updates.items.len);
    try std.testing.expectEqual(Position{ .x = -8, .y = 11 }, parent.children.items[0].position);
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(i32, 71), child.current_offset_x);
    try std.testing.expectEqual(@as(i32, -29), child.current_offset_y);
    try std.testing.expectEqual(Position{ .x = -8, .y = 11 }, listener_state.last_stack_child_positions[0]);
    try std.testing.expect(client.fatal() == null);
}

test "scanner place requests implement parent sentinel and sibling stacking" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try bindTestSubcompositor(&compositor, client, 4);
    for (5..9) |id| try createSurfaceResource(client, 3, @intCast(id));
    try getSubsurface(client, 4, 9, 6, 5);
    try getSubsurface(client, 4, 10, 7, 5);
    try getSubsurface(client, 4, 11, 8, 5);
    const parent = compositor.surfaceForId(compositor.surfaceId(client, 5).?).?;
    const a = compositor.surfaceId(client, 6).?;
    const b = compositor.surfaceId(client, 7).?;
    const c = compositor.surfaceId(client, 8).?;
    try expectPendingChildren(parent, &.{ a, b, c }, 0);

    try placeSubsurface(client, 9, 5, false);
    try expectPendingChildren(parent, &.{ a, b, c }, 1);
    try placeSubsurface(client, 11, 5, true);
    try expectPendingChildren(parent, &.{ a, c, b }, 1);
    try placeSubsurface(client, 10, 8, false);
    try expectPendingChildren(parent, &.{ a, b, c }, 1);
    try placeSubsurface(client, 9, 7, true);
    try expectPendingChildren(parent, &.{ b, a, c }, 0);
    try placeSubsurface(client, 11, 5, false);
    try expectPendingChildren(parent, &.{ c, b, a }, 1);
    try placeSubsurface(client, 10, 8, false);
    try expectPendingChildren(parent, &.{ b, c, a }, 2);

    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(usize, 4), listener_state.last_parent_stack_lengths[0]);
    try std.testing.expectEqualSlices(SurfaceId, &.{ b, c, a }, listener_state.last_stack_child_ids[0..3]);
    try std.testing.expect(client.fatal() == null);
}

test "scanner get_subsurface validates roles parents and adapter ownership before mutation" {
    const Failure = enum { other_role, active_object, self_parent, descendant_parent, child_impostor, parent_impostor };
    const Case = struct {
        fn run(failure: Failure) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var registry = SurfaceRegistry.init(std.testing.allocator);
            defer registry.deinit();
            var listener_state: TestPresentationListener = .{ .registry = &registry };
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &registry, listener_state.listener());
            defer compositor.deinit();
            listener_state.compositor = &compositor;
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            var impostor: core.wl_surface.Resource = .init(std.testing.allocator, 8, 1, .client, client.ownerHooks());
            var impostor_live = false;
            defer {
                compositor.destroyClientResources(client);
                if (impostor_live) {
                    impostor.destroy();
                    impostor.deinit();
                }
                managed.destroy();
            }

            try bindCompositor(client, 3);
            try bindTestSubcompositor(&compositor, client, 4);
            for (5..8) |id| try createSurfaceResource(client, 3, @intCast(id));
            try client.installClientInitial(8, &impostor.runtime);
            impostor_live = true;
            const objects = compositor.findClient(client).?;
            const first = objects.surfaces.items[0];
            switch (failure) {
                .other_role => first.role = .other,
                .active_object => try getSubsurface(client, 4, 9, 5, 6),
                .descendant_parent => try getSubsurface(client, 4, 9, 6, 5),
                .self_parent, .child_impostor, .parent_impostor => {},
            }

            const generations_before = compositor.next_relationship_generation;
            const subsurfaces_before = objects.subsurfaces.items.len;
            const detached_before = listener_state.detached_count;
            var roles_before: [3]Surface.Role = undefined;
            var relationships_before: [3]?Relationship = undefined;
            var child_counts_before: [3]usize = undefined;
            var sentinels_before: [3]usize = undefined;
            for (objects.surfaces.items, 0..) |surface, index| {
                roles_before[index] = surface.role;
                relationships_before[index] = surface.relationship;
                child_counts_before[index] = surface.children.items.len;
                sentinels_before[index] = surface.parent_sentinel_index;
            }

            const arguments: struct { child: u32, parent: u32, code: i64 } = switch (failure) {
                .other_role => .{ .child = 5, .parent = 6, .code = core.wl_subcompositor.@"error".bad_surface },
                .active_object => .{ .child = 5, .parent = 7, .code = core.wl_subcompositor.@"error".bad_surface },
                .self_parent => .{ .child = 5, .parent = 5, .code = core.wl_subcompositor.@"error".bad_parent },
                .descendant_parent => .{ .child = 5, .parent = 6, .code = core.wl_subcompositor.@"error".bad_parent },
                .child_impostor => .{ .child = 8, .parent = 6, .code = core.wl_subcompositor.@"error".bad_surface },
                .parent_impostor => .{ .child = 5, .parent = 8, .code = core.wl_subcompositor.@"error".bad_parent },
            };
            const rejected_id: u32 = if (subsurfaces_before == 0) 9 else 10;
            try getSubsurface(client, 4, rejected_id, arguments.child, arguments.parent);

            const fatal = client.fatal().?;
            try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
            try std.testing.expectEqual(@as(?u32, @intCast(arguments.code)), fatal.protocol_code);
            try std.testing.expectEqual(@as(u32, 4), fatal.object_id);
            try std.testing.expect(client.lookup(rejected_id) == null);
            try std.testing.expectEqual(generations_before, compositor.next_relationship_generation);
            try std.testing.expectEqual(subsurfaces_before, objects.subsurfaces.items.len);
            try std.testing.expectEqual(detached_before, listener_state.detached_count);
            for (objects.surfaces.items, 0..) |surface, index| {
                try std.testing.expectEqual(roles_before[index], surface.role);
                try std.testing.expectEqual(relationships_before[index], surface.relationship);
                try std.testing.expectEqual(child_counts_before[index], surface.children.items.len);
                try std.testing.expectEqual(sentinels_before[index], surface.parent_sentinel_index);
            }
        }
    };

    inline for (std.meta.tags(Failure)) |failure| try Case.run(failure);
}

test "scanner object validation rejects unknown dead wrong-interface and foreign surfaces" {
    const Failure = enum { unknown, dead, wrong_interface };
    const Case = struct {
        fn run(failure: Failure) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var registry = SurfaceRegistry.init(std.testing.allocator);
            defer registry.deinit();
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &registry, null);
            defer compositor.deinit();
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }

            try bindCompositor(client, 3);
            try bindTestSubcompositor(&compositor, client, 4);
            try createSurfaceResource(client, 3, 5);
            try createSurfaceResource(client, 3, 6);
            if (failure == .dead) try send(client, 6, 0, &core.wl_surface.request_messages[0], &.{});
            const child: u32 = switch (failure) {
                .unknown => 99,
                .dead => 6,
                .wrong_interface => 3,
            };
            try getSubsurface(client, 4, 7, child, 5);
            const fatal = client.fatal().?;
            try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
            try std.testing.expect(fatal.protocol_code == null);
            try std.testing.expectEqual(@as(u32, 4), fatal.object_id);
            try std.testing.expect(client.lookup(7) == null);
            try std.testing.expectEqual(@as(usize, 0), compositor.findClient(client).?.subsurfaces.items.len);
            try std.testing.expect(compositor.surfaceForId(compositor.surfaceId(client, 5).?).?.relationship == null);
        }
    };
    inline for (std.meta.tags(Failure)) |failure| try Case.run(failure);

    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, null);
    defer compositor.deinit();
    const first = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const second = try server.CoreClient.create(std.testing.allocator, &host, .{});
    defer {
        compositor.destroyClientResources(second.client());
        second.destroy();
        compositor.destroyClientResources(first.client());
        first.destroy();
    }
    try bindCompositor(first.client(), 3);
    try createSurfaceResource(first.client(), 3, 4);
    try bindCompositor(second.client(), 3);
    try createSurfaceResource(second.client(), 3, 4);
    const first_objects = compositor.findClient(first.client()).?;
    const foreign = compositor.findClient(second.client()).?.surfaces.items[0];
    try std.testing.expect(adapterSurface(first_objects, &foreign.resource.runtime) == null);
}

test "scanner restack rejects every non-sibling reference without changing order" {
    const Failure = enum { self, unrelated, different_parent, impostor, unknown, wrong_interface };
    const Case = struct {
        fn run(failure: Failure) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var registry = SurfaceRegistry.init(std.testing.allocator);
            defer registry.deinit();
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &registry, null);
            defer compositor.deinit();
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            var impostor: core.wl_surface.Resource = .init(std.testing.allocator, 13, 1, .client, client.ownerHooks());
            var impostor_live = false;
            defer {
                compositor.destroyClientResources(client);
                if (impostor_live) {
                    impostor.destroy();
                    impostor.deinit();
                }
                managed.destroy();
            }

            try bindCompositor(client, 3);
            try bindTestSubcompositor(&compositor, client, 4);
            for (5..10) |id| try createSurfaceResource(client, 3, @intCast(id));
            try getSubsurface(client, 4, 10, 6, 5);
            try getSubsurface(client, 4, 11, 7, 5);
            try getSubsurface(client, 4, 12, 8, 9);
            try client.installClientInitial(13, &impostor.runtime);
            impostor_live = true;
            const parent = compositor.surfaceForId(compositor.surfaceId(client, 5).?).?;
            const a = compositor.surfaceId(client, 6).?;
            const b = compositor.surfaceId(client, 7).?;
            try expectPendingChildren(parent, &.{ a, b }, 0);
            const reference: u32 = switch (failure) {
                .self => 6,
                .unrelated => 9,
                .different_parent => 8,
                .impostor => 13,
                .unknown => 99,
                .wrong_interface => 4,
            };
            try placeSubsurface(client, 10, reference, failure != .unrelated);
            const fatal = client.fatal().?;
            try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
            if (failure == .unknown or failure == .wrong_interface) {
                try std.testing.expect(fatal.protocol_code == null);
            } else {
                try std.testing.expectEqual(
                    @as(?u32, @intCast(core.wl_subsurface.@"error".bad_surface)),
                    fatal.protocol_code,
                );
            }
            try expectPendingChildren(parent, &.{ a, b }, 0);
        }
    };
    inline for (std.meta.tags(Failure)) |failure| try Case.run(failure);
}

test "scanner subsurface destroy discards queued work and permits permanent-role recreation" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try bindTestSubcompositor(&compositor, client, 4);
    for (5..8) |id| try createSurfaceResource(client, 3, @intCast(id));
    const child_id = compositor.surfaceId(client, 5).?;
    const first_parent = compositor.surfaceForId(compositor.surfaceId(client, 6).?).?;
    const second_parent = compositor.surfaceForId(compositor.surfaceId(client, 7).?).?;
    const child = compositor.surfaceForId(child_id).?;
    try getSubsurface(client, 4, 8, 5, 6);
    const first_generation = child.relationship.?.identity.generation;
    try commitSurfaceResource(client, 6);
    try std.testing.expect(!child.relationship.?.detached);
    try requestFrame(client, 5, 9);
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(usize, 1), child.content_updates.items.len);
    switch (child.frame_callbacks.items[0].state) {
        .queued => {},
        .pending, .committed => return error.TestExpectedQueuedCallback,
    }

    try destroySubsurfaceResource(client, 8);
    try std.testing.expectEqual(@as(usize, 0), child.content_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), child.frame_callbacks.items.len);
    try std.testing.expect(client.lookup(9) == null);
    try std.testing.expectEqual(@as(usize, 2), listener_state.detached_count);
    try std.testing.expectEqual(Surface.Role.subsurface, child.role);
    try std.testing.expect(child.active_subsurface == null);
    try std.testing.expect(child.relationship == null);
    try expectPendingChildren(first_parent, &.{}, 0);
    const retired = try drain(client);
    defer std.testing.allocator.free(retired);
    try expectDeleteIds(retired, &.{ 9, 8 });

    try getSubsurface(client, 4, 10, 5, 7);
    try std.testing.expect(child.relationship.?.identity.generation > first_generation);
    try std.testing.expectEqual(second_parent.id, child.relationship.?.identity.parent);
    try std.testing.expect(child.relationship.?.local_sync);
    try std.testing.expectEqual(Position{}, child.relationship.?.position);
    try expectPendingChildren(second_parent, &.{child_id}, 0);
    try send(client, 4, 0, &core.wl_subcompositor.request_messages[0], &.{});
    try std.testing.expect(client.lookup(4) == null);
    try setSubsurfacePosition(client, 10, -4, 6);
    try destroySubsurfaceResource(client, 10);
    try send(client, 5, 0, &core.wl_surface.request_messages[0], &.{});
    try std.testing.expect(!compositor.containsSurface(child_id));
    try std.testing.expect(client.fatal() == null);
}

test "wl_surface destroy preserves a live subsurface role object on defunct error" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, null);
    defer compositor.deinit();
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try bindTestSubcompositor(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    try createSurfaceResource(client, 3, 6);
    try getSubsurface(client, 4, 7, 5, 6);
    const child_id = compositor.surfaceId(client, 5).?;
    const child = compositor.surfaceForId(child_id).?;
    const relationship = child.relationship.?;
    try send(client, 5, 0, &core.wl_surface.request_messages[0], &.{});
    const fatal = client.fatal().?;
    try std.testing.expectEqual(server.Fatal.Kind.protocol, fatal.kind);
    try std.testing.expectEqual(
        @as(?u32, @intCast(core.wl_surface.@"error".defunct_role_object)),
        fatal.protocol_code,
    );
    try std.testing.expectEqual(@as(u32, 5), fatal.object_id);
    try std.testing.expect(compositor.containsSurface(child_id));
    try std.testing.expectEqual(Surface.Role.subsurface, child.role);
    try std.testing.expect(child.active_subsurface != null);
    try std.testing.expectEqual(relationship, child.relationship.?);
    try std.testing.expect(client.lookup(5) != null);
    try std.testing.expect(client.lookup(7) != null);
}

test "destroying a parent unmaps children but leaves their role resources inert" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try bindTestSubcompositor(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    try createSurfaceResource(client, 3, 6);
    try getSubsurface(client, 4, 7, 5, 6);
    const child_id = compositor.surfaceId(client, 5).?;
    const parent_id = compositor.surfaceId(client, 6).?;
    const child = compositor.surfaceForId(child_id).?;
    const identity = child.relationship.?.identity;
    try commitSurfaceResource(client, 6);
    try std.testing.expect(!child.relationship.?.detached);
    try send(client, 6, 0, &core.wl_surface.request_messages[0], &.{});
    try std.testing.expect(!compositor.containsSurface(parent_id));
    try std.testing.expect(compositor.containsSurface(child_id));
    try std.testing.expectEqual(identity, child.relationship.?.identity);
    try std.testing.expect(child.active_subsurface != null);
    try std.testing.expect(child.relationship.?.detached);
    try std.testing.expectEqual(@as(usize, 2), listener_state.detached_count);

    // With no live parent, non-destructor role requests have no state to
    // modify. The role object remains live solely so lifecycle ordering and
    // defunct_role_object stay exact until the client destroys it.
    try setSubsurfacePosition(client, 7, 20, 30);
    try setSubsurfaceMode(client, 7, false);
    try std.testing.expectEqual(Position{}, child.relationship.?.position);
    try std.testing.expect(child.relationship.?.local_sync);
    try std.testing.expect(client.fatal() == null);
    try destroySubsurfaceResource(client, 7);
    try std.testing.expectEqual(@as(usize, 2), listener_state.detached_count);
    try std.testing.expect(child.relationship == null);
    try send(client, 5, 0, &core.wl_surface.request_messages[0], &.{});
    try std.testing.expect(!compositor.containsSurface(child_id));
    try std.testing.expect(client.fatal() == null);
}

test "disconnect destroys subsurface records before surfaces without duplicate detach" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    var managed_live = true;
    defer if (managed_live) {
        compositor.destroyClientResources(client);
        managed.destroy();
    };
    try bindCompositor(client, 3);
    try bindTestSubcompositor(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    try createSurfaceResource(client, 3, 6);
    try getSubsurface(client, 4, 7, 5, 6);
    try commitSurfaceResource(client, 6);
    try std.testing.expectEqual(@as(usize, 1), listener_state.detached_count);
    compositor.destroyClientResources(client);
    try std.testing.expectEqual(@as(usize, 2), listener_state.detached_count);
    try std.testing.expectEqual(@as(usize, 2), listener_state.removing_count);
    try std.testing.expectEqual(@as(usize, 0), compositor.surfaceCount());
    try std.testing.expectEqual(@as(usize, 0), registry.len());
    managed.destroy();
    managed_live = false;
}

test "subcompositor binding OOM rolls back stable records lists and new ids" {
    const Case = struct {
        fn run(fail_offset: usize) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var registry = SurfaceRegistry.init(std.testing.allocator);
            defer registry.deinit();
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var compositor: WayringCompositor = undefined;
            try compositor.init(failing.allocator(), &host, &registry, null);
            defer compositor.deinit();
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }
            try bindCompositor(client, 3);
            const objects = compositor.findClient(client).?;
            const live_before = failing.allocated_bytes - failing.freed_bytes;
            const bind_request = try encode(2, 0, &core.wl_registry.request_messages[0], &.{
                .{ .uint = compositor.subcompositor_global.name() },
                .{ .new_id = .{ .generic = .{ .interface = "wl_subcompositor", .version = 1, .id = 4 } } },
            });
            defer std.testing.allocator.free(bind_request);
            try client.receive(bind_request, &.{});
            failing.fail_index = failing.alloc_index + fail_offset;
            try client.dispatch();
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
            try std.testing.expect(client.lookup(4) == null);
            try std.testing.expectEqual(@as(usize, 0), objects.subcompositors.items.len);
            try std.testing.expectEqual(@as(usize, 0), objects.subcompositors.capacity);
            try std.testing.expectEqual(live_before, failing.allocated_bytes - failing.freed_bytes);
        }
    };
    try Case.run(0);
    try Case.run(1);
}

test "get_subsurface OOM preserves role topology ownership and reserved new id" {
    const Case = struct {
        fn run(fail_offset: usize) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var registry = SurfaceRegistry.init(std.testing.allocator);
            defer registry.deinit();
            var listener_state: TestPresentationListener = .{ .registry = &registry };
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var compositor: WayringCompositor = undefined;
            try compositor.init(failing.allocator(), &host, &registry, listener_state.listener());
            defer compositor.deinit();
            listener_state.compositor = &compositor;
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }
            try bindCompositor(client, 3);
            try bindTestSubcompositor(&compositor, client, 4);
            try createSurfaceResource(client, 3, 5);
            try createSurfaceResource(client, 3, 6);
            const objects = compositor.findClient(client).?;
            const child = compositor.surfaceForId(compositor.surfaceId(client, 5).?).?;
            const parent = compositor.surfaceForId(compositor.surfaceId(client, 6).?).?;
            const generation_before = compositor.next_relationship_generation;
            const live_before = failing.allocated_bytes - failing.freed_bytes;
            const request = try encode(4, 1, &core.wl_subcompositor.request_messages[1], &.{
                .{ .new_id = .{ .typed = 7 } }, .{ .object = 5 }, .{ .object = 6 },
            });
            defer std.testing.allocator.free(request);
            try client.receive(request, &.{});
            failing.fail_index = failing.alloc_index + fail_offset;
            try client.dispatch();
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
            try std.testing.expect(client.lookup(7) == null);
            try std.testing.expectEqual(Surface.Role.none, child.role);
            try std.testing.expect(child.active_subsurface == null);
            try std.testing.expect(child.relationship == null);
            try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);
            try std.testing.expectEqual(@as(usize, 0), parent.children.capacity);
            try std.testing.expectEqual(@as(usize, 0), objects.subsurfaces.items.len);
            try std.testing.expectEqual(@as(usize, 0), objects.subsurfaces.capacity);
            try std.testing.expectEqual(generation_before, compositor.next_relationship_generation);
            try std.testing.expectEqual(@as(usize, 0), listener_state.detached_count);
            try std.testing.expectEqual(live_before, failing.allocated_bytes - failing.freed_bytes);
        }
    };
    try Case.run(0); // per-client subsurface pointer list
    try Case.run(1); // parent pending children storage
    try Case.run(2); // heap-stable Subsurface record
}

test "protocol set_desync scratch failures preserve mode claims queues and applied state" {
    const Case = struct {
        fn run(fault: CommitFault) !void {
            var host: server.Server = .init(std.testing.allocator);
            defer host.deinit();
            var registry = SurfaceRegistry.init(std.testing.allocator);
            defer registry.deinit();
            var listener_state: TestPresentationListener = .{ .registry = &registry };
            var compositor: WayringCompositor = undefined;
            try compositor.init(std.testing.allocator, &host, &registry, listener_state.listener());
            defer compositor.deinit();
            listener_state.compositor = &compositor;
            const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
            const client = managed.client();
            defer {
                compositor.destroyClientResources(client);
                managed.destroy();
            }
            try bindCompositor(client, 3);
            try bindTestSubcompositor(&compositor, client, 4);
            try createSurfaceResource(client, 3, 5);
            try createSurfaceResource(client, 3, 6);
            try getSubsurface(client, 4, 7, 5, 6);
            const child = compositor.surfaceForId(compositor.surfaceId(client, 5).?).?;
            try requestFrame(client, 5, 8);
            try commitSurfaceResource(client, 5);
            const token = child.content_updates.items[0].token;
            const callbacks = child.content_updates.items[0].callback_count;
            const detached_before = listener_state.detached_count;
            compositor.commit_fault = fault;
            try setSubsurfaceMode(client, 7, false);
            try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
            try std.testing.expect(child.relationship.?.local_sync);
            try std.testing.expectEqual(@as(usize, 1), child.content_updates.items.len);
            try std.testing.expectEqual(token, child.content_updates.items[0].token);
            try std.testing.expectEqual(UpdateKind.scu, child.content_updates.items[0].kind);
            try std.testing.expect(child.content_updates.items[0].claimed_by == null);
            try std.testing.expectEqual(callbacks, child.content_updates.items[0].callback_count);
            try std.testing.expectEqual(@as(usize, 1), child.frame_callbacks.items.len);
            try std.testing.expectEqual(detached_before, listener_state.detached_count);
            try std.testing.expectEqual(@as(usize, 0), listener_state.committed_count);
        }
    };
    try Case.run(.apply_scratch);
    try Case.run(.batch_assembly);
}

test "destroying a synchronized ancestor role unlocks local-desync descendant SCUs" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }
    try bindCompositor(client, 3);
    try bindTestSubcompositor(&compositor, client, 4);
    for (5..8) |id| try createSurfaceResource(client, 3, @intCast(id));
    try getSubsurface(client, 4, 8, 6, 5);
    try getSubsurface(client, 4, 9, 7, 6);
    try setSubsurfaceMode(client, 9, false);
    const parent = compositor.surfaceForId(compositor.surfaceId(client, 6).?).?;
    const child = compositor.surfaceForId(compositor.surfaceId(client, 7).?).?;
    try std.testing.expect(!child.relationship.?.local_sync);
    try std.testing.expect(compositor.effectivelySynchronized(child));
    try requestFrame(client, 7, 10);
    try commitSurfaceResource(client, 7);
    try std.testing.expectEqual(UpdateKind.scu, child.content_updates.items[0].kind);
    try std.testing.expectEqual(@as(usize, 0), listener_state.committed_count);

    try destroySubsurfaceResource(client, 8);
    try std.testing.expect(parent.relationship == null);
    try std.testing.expect(parent.active_subsurface == null);
    try std.testing.expect(!compositor.effectivelySynchronized(child));
    try std.testing.expectEqual(@as(usize, 0), child.content_updates.items.len);
    try std.testing.expectEqual(@as(usize, 1), listener_state.committed_count);
    switch (child.frame_callbacks.items[0].state) {
        .committed => {},
        .pending, .queued => return error.TestExpectedCommittedCallback,
    }

    // Later child commits are ordinary DCUs rather than being blocked behind
    // the former SCU forever.
    try commitSurfaceResource(client, 7);
    try std.testing.expectEqual(@as(usize, 0), child.content_updates.items.len);
    try std.testing.expectEqual(@as(usize, 2), listener_state.committed_count);
    try std.testing.expect(client.fatal() == null);
}

test "ancestor role destroy scratch OOM leaves resources topology and SCUs unchanged" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }
    try bindCompositor(client, 3);
    try bindTestSubcompositor(&compositor, client, 4);
    for (5..8) |id| try createSurfaceResource(client, 3, @intCast(id));
    try getSubsurface(client, 4, 8, 6, 5);
    try getSubsurface(client, 4, 9, 7, 6);
    try setSubsurfaceMode(client, 9, false);
    const grandparent = compositor.surfaceForId(compositor.surfaceId(client, 5).?).?;
    const parent = compositor.surfaceForId(compositor.surfaceId(client, 6).?).?;
    const child = compositor.surfaceForId(compositor.surfaceId(client, 7).?).?;
    try requestFrame(client, 7, 10);
    try commitSurfaceResource(client, 7);
    const parent_identity = parent.relationship.?.identity;
    const child_token = child.content_updates.items[0].token;
    const detached_before = listener_state.detached_count;
    compositor.commit_fault = .apply_scratch;
    try destroySubsurfaceResource(client, 8);

    try std.testing.expectEqual(server.Fatal.Kind.out_of_memory, client.fatal().?.kind);
    try std.testing.expectEqual(&parent.active_subsurface.?.resource.runtime, client.lookup(8).?);
    try std.testing.expectEqual(parent_identity, parent.relationship.?.identity);
    try std.testing.expectEqual(@as(usize, 1), grandparent.children.items.len);
    try std.testing.expectEqual(parent_identity, grandparent.children.items[0].identity);
    try std.testing.expectEqual(@as(usize, 1), child.content_updates.items.len);
    try std.testing.expectEqual(child_token, child.content_updates.items[0].token);
    try std.testing.expectEqual(UpdateKind.scu, child.content_updates.items[0].kind);
    try std.testing.expect(child.content_updates.items[0].claimed_by == null);
    try std.testing.expect(!child.relationship.?.local_sync);
    switch (child.frame_callbacks.items[0].state) {
        .queued => {},
        .pending, .committed => return error.TestExpectedQueuedCallback,
    }
    try std.testing.expectEqual(detached_before, listener_state.detached_count);
    try std.testing.expectEqual(@as(usize, 0), listener_state.committed_count);
}

test "exact CU tails apply one nested batch without consuming a later child update" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try bindTestSubcompositor(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    try createSurfaceResource(client, 3, 6);
    try createSurfaceResource(client, 3, 7);
    const root_id = compositor.surfaceId(client, 5).?;
    const parent_id = compositor.surfaceId(client, 6).?;
    const child_id = compositor.surfaceId(client, 7).?;
    const root = compositor.surfaceForId(root_id).?;
    const parent = compositor.surfaceForId(parent_id).?;
    const child = compositor.surfaceForId(child_id).?;
    try getSubsurface(client, 4, 8, 6, 5);
    try getSubsurface(client, 4, 9, 7, 6);
    try setSubsurfacePosition(client, 8, 10, 4);
    try setSubsurfacePosition(client, 9, 3, -2);

    try commitSurfaceResource(client, 7);
    try std.testing.expectEqual(@as(usize, 1), child.content_updates.items.len);
    try std.testing.expectEqual(UpdateKind.scu, child.content_updates.items[0].kind);
    const child_n = child.content_updates.items[0].token;
    try commitSurfaceResource(client, 6);
    try std.testing.expectEqual(@as(usize, 1), parent.content_updates.items.len);
    try std.testing.expectEqual(@as(usize, 1), parent.content_updates.items[0].claims.items.len);
    try std.testing.expectEqual(child_n, parent.content_updates.items[0].claims.items[0].token);
    try std.testing.expectEqual(parent.content_updates.items[0].token, child.content_updates.items[0].claimed_by.?);

    // A second parent CU cannot claim the already-owned tail.
    try commitSurfaceResource(client, 6);
    try std.testing.expectEqual(@as(usize, 2), parent.content_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), parent.content_updates.items[1].claims.items.len);

    // This later child CU is not reachable through the parent's exact N claim.
    try commitSurfaceResource(client, 7);
    try std.testing.expectEqual(@as(usize, 2), child.content_updates.items.len);
    const child_n_plus_one = child.content_updates.items[1].token;
    try std.testing.expect(child_n_plus_one.sequence > child_n.sequence);
    const commits_before_root = listener_state.committed_count;
    try commitSurfaceResource(client, 5);

    try std.testing.expectEqual(commits_before_root + 1, listener_state.committed_count);
    try std.testing.expectEqual(@as(usize, 3), listener_state.last_batch_surface_count);
    try std.testing.expectEqualSlices(
        SurfaceId,
        &.{ child_id, parent_id, root_id },
        listener_state.last_batch_surface_ids[0..3],
    );
    try std.testing.expectEqual(@as(usize, 2), listener_state.last_batch_parent_count);
    try std.testing.expectEqualSlices(
        SurfaceId,
        &.{ parent_id, root_id },
        listener_state.last_batch_parent_ids[0..2],
    );
    try std.testing.expectEqualSlices(
        SurfaceId,
        &.{ child_id, parent_id },
        listener_state.last_stack_child_ids[0..2],
    );
    try std.testing.expectEqual(Position{ .x = 3, .y = -2 }, listener_state.last_stack_child_positions[0]);
    try std.testing.expectEqual(Position{ .x = 10, .y = 4 }, listener_state.last_stack_child_positions[1]);
    try std.testing.expectEqual(@as(usize, 1), child.content_updates.items.len);
    try std.testing.expectEqual(child_n_plus_one, child.content_updates.items[0].token);
    try std.testing.expectEqual(@as(usize, 0), parent.content_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), root.content_updates.items.len);

    // Desync under a synchronized ancestor does not flush, and set_sync never
    // flushes. Unlocking that ancestor reaches only local-desync descendants.
    try setSubsurfaceMode(client, 9, false);
    try std.testing.expectEqual(@as(usize, 1), child.content_updates.items.len);
    try setSubsurfaceMode(client, 9, true);
    try std.testing.expectEqual(@as(usize, 1), child.content_updates.items.len);
    try setSubsurfaceMode(client, 9, false);

    try createSurfaceResource(client, 3, 10);
    const grandchild_id = compositor.surfaceId(client, 10).?;
    const grandchild = compositor.surfaceForId(grandchild_id).?;
    try getSubsurface(client, 4, 11, 10, 7);
    try commitSurfaceResource(client, 10);
    try std.testing.expectEqual(@as(usize, 1), grandchild.content_updates.items.len);

    try setSubsurfaceMode(client, 8, false);
    try std.testing.expectEqual(@as(usize, 0), child.content_updates.items.len);
    try std.testing.expectEqual(@as(usize, 1), grandchild.content_updates.items.len);
    try setSubsurfaceMode(client, 11, false);
    try std.testing.expectEqual(@as(usize, 0), grandchild.content_updates.items.len);
    try std.testing.expect(client.fatal() == null);
}

test "queued CU projection and callbacks follow exact update application" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositorVersion(client, 3, 6);
    try bindShm(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    try createSurfaceResource(client, 3, 6);
    const preferences = try drain(client);
    defer std.testing.allocator.free(preferences);
    try std.testing.expectEqual(@as(usize, 48), preferences.len);
    const root_id = compositor.surfaceId(client, 5).?;
    const child_id = compositor.surfaceId(client, 6).?;
    const root = compositor.surfaceForId(root_id).?;
    const child = compositor.surfaceForId(child_id).?;
    _ = try compositor.testAssociate(child_id, root_id);

    const pixels: [8]u32 = .{
        0xff01_0203, 0xff04_0506, 0xff07_0809, 0xff0a_0b0c,
        0xff10_2030, 0xff40_5060, 0xff70_8090, 0xffa0_b0c0,
    };
    const fd = try memfdWithPixels(&pixels);
    defer _ = std.c.close(fd);
    try createShmPool(client, 4, 7, fd, @sizeOf(@TypeOf(pixels)));
    try createShmBuffer(client, 7, 8, 0, .{ .width = 4, .height = 2 }, 4 * @sizeOf(u32), .argb8888);

    try requestFrame(client, 6, 9);
    try attachBuffer(client, 6, 8);
    try commitSurfaceResource(client, 6);
    try requestFrame(client, 6, 10);
    try setBufferScale(client, 6, 2);
    try commitSurfaceResource(client, 6);
    try setBufferTransform(client, 6, @intCast(core.wl_output.transform.@"90"));
    try commitSurfaceResource(client, 6);

    try std.testing.expectEqual(@as(usize, 3), child.content_updates.items.len);
    try std.testing.expectEqual(render.Size{ .width = 4, .height = 2 }, child.content_updates.items[0].prepared.physical_size.?);
    try std.testing.expectEqual(render.Size{ .width = 4, .height = 2 }, child.content_updates.items[0].prepared.logical_size.?);
    try std.testing.expectEqual(render.Size{ .width = 2, .height = 1 }, child.content_updates.items[1].prepared.logical_size.?);
    try std.testing.expectEqual(render.Size{ .width = 1, .height = 2 }, child.content_updates.items[2].prepared.logical_size.?);
    try std.testing.expectEqual(@as(u64, 1), child.content_updates.items[0].prepared.buffer.?.source_cache.version);
    try std.testing.expectEqual(@as(u64, 2), child.next_source_version);
    try std.testing.expect(child.content_updates.items[1].prepared.buffer == null);
    try std.testing.expect(child.content_updates.items[2].prepared.buffer == null);
    try std.testing.expectEqual(UpdateKind.scu, child.content_updates.items[2].kind);

    const released = try drain(client);
    defer std.testing.allocator.free(released);
    try std.testing.expectEqual(@as(usize, 8), released.len);
    listener_state.frame_completion.?.complete(listener_state.frame_completion.?.context, child_id, 40);
    const queued_not_done = try drain(client);
    defer std.testing.allocator.free(queued_not_done);
    try std.testing.expectEqual(@as(usize, 0), queued_not_done.len);

    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(usize, 0), child.content_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), root.content_updates.items.len);
    const state = registry.renderState(child_id).?;
    try std.testing.expectEqual(render.Size{ .width = 1, .height = 2 }, state.logical_size);
    try std.testing.expectEqual(render.BufferTransform.rotate_90, state.transform);
    try std.testing.expectEqual(@as(u64, 1), state.buffer.source_cache.?.version);
    try std.testing.expectEqualSlices(u32, &pixels, state.buffer.pixels);
    try std.testing.expectEqualSlices(SurfaceId, &.{ child_id, root_id }, listener_state.last_batch_surface_ids[0..2]);
    try std.testing.expect(listener_state.last_batch_callbacks[0]);
    listener_state.frame_completion.?.complete(listener_state.frame_completion.?.context, child_id, 41);
    const callback_done = try drain(client);
    defer std.testing.allocator.free(callback_done);
    try std.testing.expectEqual(@as(usize, 48), callback_done.len);
    try expectCallbackDoneAndDelete(callback_done, 0, 9, 41);
    try expectCallbackDoneAndDelete(callback_done, 24, 10, 41);

    // A null attachment projects through the next state-only SCU, and its
    // callback remains committed demand even though the final content is null.
    try requestFrame(client, 6, 11);
    try attachBuffer(client, 6, null);
    try commitSurfaceResource(client, 6);
    try setBufferScale(client, 6, 1);
    try commitSurfaceResource(client, 6);
    try std.testing.expectEqual(@as(usize, 2), child.content_updates.items.len);
    try std.testing.expect(child.content_updates.items[0].prepared.physical_size == null);
    try std.testing.expect(child.content_updates.items[0].prepared.logical_size == null);
    try std.testing.expect(child.content_updates.items[1].prepared.physical_size == null);
    try std.testing.expect(child.content_updates.items[1].prepared.logical_size == null);
    try commitSurfaceResource(client, 5);
    try std.testing.expect(registry.renderState(child_id) == null);
    try std.testing.expect(listener_state.last_batch_callbacks[0]);
    listener_state.frame_completion.?.complete(listener_state.frame_completion.?.context, child_id, 42);
    const hidden_done = try drain(client);
    defer std.testing.allocator.free(hidden_done);
    try expectCallbackDoneAndDelete(hidden_done, 0, 11, 42);

    // Discarding a queued CU retires its exact callback without wl_callback.done.
    try requestFrame(client, 6, 12);
    try commitSurfaceResource(client, 6);
    try std.testing.expectEqual(@as(usize, 1), child.content_updates.items.len);
    try send(client, 6, 0, &core.wl_surface.request_messages[0], &.{});
    try std.testing.expect(client.lookup(12) == null);
    try std.testing.expect(!compositor.containsSurface(child_id));
    try std.testing.expect(client.fatal() == null);
}

test "stale association and canonical generations cannot alias replacement topology" {
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var listener_state: TestPresentationListener = .{ .registry = &registry };
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, listener_state.listener());
    defer compositor.deinit();
    listener_state.compositor = &compositor;
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    try bindTestSubcompositor(&compositor, client, 4);
    try createSurfaceResource(client, 3, 5);
    try createSurfaceResource(client, 3, 6);
    try createSurfaceResource(client, 3, 7);
    const parent_id = compositor.surfaceId(client, 6).?;
    const old_child_id = compositor.surfaceId(client, 7).?;
    try getSubsurface(client, 4, 8, 6, 5);
    try getSubsurface(client, 4, 9, 7, 6);
    const first_association = compositor.surfaceForId(old_child_id).?.relationship.?.identity.generation;
    try commitSurfaceResource(client, 6);
    try destroySubsurfaceResource(client, 9);
    try getSubsurface(client, 4, 10, 7, 6);
    const second_association = compositor.surfaceForId(old_child_id).?.relationship.?.identity.generation;
    try std.testing.expect(second_association > first_association);
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(usize, 2), listener_state.last_batch_parent_count);
    try std.testing.expectEqual(@as(usize, 1), listener_state.last_parent_stack_lengths[0]);
    try std.testing.expectEqual(@as(usize, 1), listener_state.last_stack_child_count);
    try std.testing.expectEqual(parent_id, listener_state.last_stack_child_ids[0]);

    // Queue another old-child topology, then replace the provider in the same
    // registry slot before its synchronized CU applies.
    try commitSurfaceResource(client, 6);
    try destroySubsurfaceResource(client, 10);
    try send(client, 7, 0, &core.wl_surface.request_messages[0], &.{});
    try createSurfaceResource(client, 3, 11);
    const replacement_id = compositor.surfaceId(client, 11).?;
    try std.testing.expectEqual(old_child_id.index, replacement_id.index);
    try std.testing.expect(old_child_id.generation != replacement_id.generation);
    try getSubsurface(client, 4, 12, 11, 6);
    try commitSurfaceResource(client, 5);
    try std.testing.expectEqual(@as(usize, 1), listener_state.last_parent_stack_lengths[0]);
    try std.testing.expectEqual(@as(usize, 1), listener_state.last_stack_child_count);
    try std.testing.expectEqual(parent_id, listener_state.last_stack_child_ids[0]);
    try std.testing.expect(!std.meta.eql(replacement_id, listener_state.last_stack_child_ids[0]));
    try std.testing.expect(client.fatal() == null);
}

test "hostile-depth CU traversal is iterative and relationship cycles are rejected" {
    const depth = 128;
    var host: server.Server = .init(std.testing.allocator);
    defer host.deinit();
    var registry = SurfaceRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var compositor: WayringCompositor = undefined;
    try compositor.init(std.testing.allocator, &host, &registry, null);
    defer compositor.deinit();
    const managed = try server.CoreClient.create(std.testing.allocator, &host, .{});
    const client = managed.client();
    defer {
        compositor.destroyClientResources(client);
        managed.destroy();
    }

    try bindCompositor(client, 3);
    var ids: [depth]SurfaceId = undefined;
    for (0..depth) |index| {
        const object_id: u32 = @intCast(4 + index);
        try createSurfaceResource(client, 3, object_id);
        ids[index] = compositor.surfaceId(client, object_id).?;
    }
    for (1..depth) |index| _ = try compositor.testAssociate(ids[index], ids[index - 1]);
    try std.testing.expectError(error.RelationshipCycle, compositor.testAssociate(ids[0], ids[depth - 1]));
    try std.testing.expect(compositor.surfaceForId(ids[0]).?.relationship == null);

    var index: usize = depth;
    while (index > 1) {
        index -= 1;
        try commitSurfaceResource(client, @intCast(4 + index));
    }
    try commitSurfaceResource(client, 4);
    for (ids) |id| try std.testing.expectEqual(
        @as(usize, 0),
        compositor.surfaceForId(id).?.content_updates.items.len,
    );
    try std.testing.expect(client.fatal() == null);
}
