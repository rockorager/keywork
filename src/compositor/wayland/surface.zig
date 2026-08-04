//! Server-side wl_surface state and compositor-owned buffer snapshots.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const DrmSyncobj = @import("../drm_syncobj.zig");
const presentation = @import("../presentation.zig");
const Region = @import("../region.zig");
const render_types = @import("../render/types.zig");
const slot_map = @import("../slot_map.zig");
const CopiedBufferSnapshot = @import("CopiedBufferSnapshot.zig");
const surface_geometry = @import("surface_geometry.zig");
const WaylandRegion = @import("region.zig");
const LinuxDmabuf = @import("linux_dmabuf.zig");
const SinglePixelBuffer = @import("single_pixel_buffer.zig");

const wl = wayland.server.wl;
const wp = wayland.server.wp;
const log = std.log.scoped(.surface);

allocator: std.mem.Allocator,
store: *Store,
id: Id,
resource: *wl.Surface,
pending_attachment: Attachment,
has_pending_attachment: bool,
role_handler: ?RoleHandler,
viewport_handler: ?ViewportHandler,
content_type_handler: ?ContentTypeHandler,
color_representation_handler: ?ColorRepresentationHandler,
alpha_modifier_handler: ?AlphaModifierHandler,
tearing_control_handler: ?TearingControlHandler,
fifo_handler: ?FifoHandler,
commit_timer_handler: ?CommitTimerHandler,
background_effect_handler: ?BackgroundEffectHandler,
explicit_sync_handler: ?ExplicitSyncHandler,
commit_listeners: std.ArrayList(*CommitListener),
notifying_commit_listeners: bool,

pub const Store = slot_map.SlotMap(State, enum { surface });
pub const Id = Store.Id;

pub const State = struct {
    resource: *wl.Surface,
    pending_offset_x: i32,
    pending_offset_y: i32,
    current_offset_x: i32,
    current_offset_y: i32,
    pending_scale: i32,
    current_scale: i32,
    pending_transform: wl.Output.Transform,
    current_transform: wl.Output.Transform,
    pending_viewport: ViewportState,
    current_viewport: ViewportState,
    pending_content_type: ContentType,
    current_content_type: ContentType,
    pending_color_description: render_types.ColorDescription,
    current_color_description: render_types.ColorDescription,
    pending_color_representation: ColorRepresentationState,
    current_color_representation: ColorRepresentationState,
    pending_alpha_multiplier: u32,
    current_alpha_multiplier: u32,
    pending_presentation_hint: PresentationHint,
    current_presentation_hint: PresentationHint,
    pending_fifo_set: bool,
    pending_fifo_wait: bool,
    fifo_barrier: bool,
    fifo_barrier_output: ?*anyopaque,
    pending_commit_timestamp: ?i96,
    pending_timing_ready: bool,
    pending_blur_region: Region,
    pending_blur_region_changed: bool,
    current_blur_region: Region,
    pending_surface_damage: Region,
    pending_buffer_damage: Region,
    current_damage: Region,
    current_damage_precise: bool,
    pending_opaque: Region,
    current_opaque: Region,
    pending_input: InputRegion,
    current_input: InputRegion,
    callbacks: std.ArrayList(*FrameCallback),
    release_callbacks: std.ArrayList(*BufferReleaseCallback),
    commit_feedbacks: std.ArrayList(*CommitFeedback),
    presentation_output: ?*anyopaque,
    commit_after_submission: bool,
    preferred_buffer_scale: ?i32,
    source_cache_id: u64,
    next_source_version: u64,
    next_release_generation: u64,
    current_buffer: ?BufferSnapshot,
    cached_commits: std.ArrayList(CachedCommit),
    next_cached_sequence: u64,
    role: ?Role,
    has_committed: bool,
    has_committed_buffer: bool,

    fn init(resource: *wl.Surface) State {
        return .{
            .resource = resource,
            .pending_offset_x = 0,
            .pending_offset_y = 0,
            .current_offset_x = 0,
            .current_offset_y = 0,
            .pending_scale = 1,
            .current_scale = 1,
            .pending_transform = .normal,
            .current_transform = .normal,
            .pending_viewport = .{},
            .current_viewport = .{},
            .pending_content_type = .none,
            .current_content_type = .none,
            .pending_color_description = .{},
            .current_color_description = .{},
            .pending_color_representation = .{},
            .current_color_representation = .{},
            .pending_alpha_multiplier = std.math.maxInt(u32),
            .current_alpha_multiplier = std.math.maxInt(u32),
            .pending_presentation_hint = .vsync,
            .current_presentation_hint = .vsync,
            .pending_fifo_set = false,
            .pending_fifo_wait = false,
            .fifo_barrier = false,
            .fifo_barrier_output = null,
            .pending_commit_timestamp = null,
            .pending_timing_ready = true,
            .pending_blur_region = Region.init(),
            .pending_blur_region_changed = false,
            .current_blur_region = Region.init(),
            .pending_surface_damage = Region.init(),
            .pending_buffer_damage = Region.init(),
            .current_damage = Region.init(),
            .current_damage_precise = false,
            .pending_opaque = Region.init(),
            .current_opaque = Region.init(),
            .pending_input = InputRegion.init(),
            .current_input = InputRegion.init(),
            .callbacks = .empty,
            .release_callbacks = .empty,
            .commit_feedbacks = .empty,
            .presentation_output = null,
            .commit_after_submission = false,
            .preferred_buffer_scale = null,
            .source_cache_id = render_types.allocateSourceCacheId(),
            .next_source_version = 1,
            .next_release_generation = 1,
            .current_buffer = null,
            .cached_commits = .empty,
            .next_cached_sequence = 1,
            .role = null,
            .has_committed = false,
            .has_committed_buffer = false,
        };
    }

    fn deinit(self: *State, allocator: std.mem.Allocator) void {
        std.debug.assert(self.callbacks.items.len == 0);
        std.debug.assert(self.release_callbacks.items.len == 0);
        std.debug.assert(self.commit_feedbacks.items.len == 0);
        self.callbacks.deinit(allocator);
        self.release_callbacks.deinit(allocator);
        self.commit_feedbacks.deinit(allocator);
        if (self.current_buffer) |*current| current.deinit();
        for (self.cached_commits.items) |*cached| cached.deinit();
        self.cached_commits.deinit(allocator);
        self.pending_surface_damage.deinit();
        self.pending_buffer_damage.deinit();
        self.current_damage.deinit();
        self.pending_blur_region.deinit();
        self.current_blur_region.deinit();
        self.pending_opaque.deinit();
        self.current_opaque.deinit();
        self.pending_input.deinit();
        self.current_input.deinit();
        self.* = undefined;
    }
};

pub const CreateError = error{
    OutOfMemory,
    ResourceCreateFailed,
};

pub fn create(
    allocator: std.mem.Allocator,
    store: *Store,
    client: *wl.Client,
    version: u32,
    id: u32,
) CreateError!*Self {
    const resource = try wl.Surface.create(client, version, id);
    errdefer resource.destroy();

    const self = allocator.create(Self) catch return error.OutOfMemory;
    errdefer allocator.destroy(self);

    var surface_state = State.init(resource);
    errdefer surface_state.deinit(allocator);
    const state_id = store.insert(allocator, surface_state) catch return error.OutOfMemory;

    self.* = .{
        .allocator = allocator,
        .store = store,
        .id = state_id,
        .resource = resource,
        .pending_attachment = .{},
        .has_pending_attachment = false,
        .role_handler = null,
        .viewport_handler = null,
        .content_type_handler = null,
        .color_representation_handler = null,
        .alpha_modifier_handler = null,
        .tearing_control_handler = null,
        .fifo_handler = null,
        .commit_timer_handler = null,
        .background_effect_handler = null,
        .explicit_sync_handler = null,
        .commit_listeners = .empty,
        .notifying_commit_listeners = false,
    };

    resource.setHandler(*Self, handleRequest, handleDestroy, self);
    return self;
}

pub fn fromResource(resource: *wl.Surface) *Self {
    return @ptrCast(@alignCast(resource.getUserData().?));
}

pub fn handle(self: *const Self) Id {
    return self.id;
}

pub fn waylandResource(self: *Self) *wl.Surface {
    return self.resource;
}

pub fn state(self: *Self) *State {
    return self.store.get(self.id) orelse unreachable;
}

pub fn resourceFor(store: *Store, id: Id) ?*wl.Surface {
    const surface_state = store.get(id) orelse return null;
    return surface_state.resource;
}

pub fn currentLogicalSize(store: *Store, id: Id) ?render_types.Size {
    const surface_state = store.get(id) orelse return null;
    const buffer = surface_state.current_buffer orelse return null;
    return buffer.logical_size;
}

pub const RoleError = error{
    AlreadyAssigned,
    AlreadyReserved,
    NotReserved,
};

pub const ViewportSource = surface_geometry.ViewportSource;
pub const ViewportState = surface_geometry.ViewportState;

pub const ContentType = wp.ContentTypeV1.Type;

pub const ViewportHandler = struct {
    context: *anyopaque,
    resource: *wp.Viewport,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub fn setViewportHandler(self: *Self, handler: ViewportHandler) error{AlreadyExists}!void {
    if (self.viewport_handler != null) return error.AlreadyExists;
    self.viewport_handler = handler;
}

pub fn clearViewportHandler(self: *Self) void {
    std.debug.assert(self.viewport_handler != null);
    self.viewport_handler = null;
    self.state().pending_viewport = .{};
}

pub fn setViewportSource(self: *Self, source: ?ViewportSource) void {
    std.debug.assert(self.viewport_handler != null);
    self.state().pending_viewport.source = source;
}

pub fn setViewportDestination(self: *Self, destination: ?render_types.Size) void {
    std.debug.assert(self.viewport_handler != null);
    self.state().pending_viewport.destination = destination;
}

pub const ContentTypeHandler = struct {
    context: *anyopaque,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub fn setContentTypeHandler(self: *Self, handler: ContentTypeHandler) error{AlreadyExists}!void {
    if (self.content_type_handler != null) return error.AlreadyExists;
    self.content_type_handler = handler;
}

pub fn clearContentTypeHandler(self: *Self) void {
    std.debug.assert(self.content_type_handler != null);
    self.content_type_handler = null;
    self.state().pending_content_type = .none;
}

pub fn setPendingContentType(self: *Self, content_type: ContentType) void {
    std.debug.assert(self.content_type_handler != null);
    self.state().pending_content_type = content_type;
}

pub fn currentContentType(store: *Store, id: Id) ?ContentType {
    const surface_state = store.get(id) orelse return null;
    return surface_state.current_content_type;
}

pub fn setPendingColorDescription(self: *Self, value: render_types.ColorDescription) void {
    self.state().pending_color_description = value;
}

pub fn pendingColorDescription(self: *Self) render_types.ColorDescription {
    return self.state().pending_color_description;
}

pub fn currentColorDescription(store: *Store, id: Id) ?render_types.ColorDescription {
    const surface_state = store.get(id) orelse return null;
    return surface_state.current_color_description;
}

pub const ColorRepresentationState = struct {
    alpha_mode: ?wp.ColorRepresentationSurfaceV1.AlphaMode = null,
    coefficients: ?wp.ColorRepresentationSurfaceV1.Coefficients = null,
    range: ?wp.ColorRepresentationSurfaceV1.Range = null,
    chroma_location: ?wp.ColorRepresentationSurfaceV1.ChromaLocation = null,

    pub fn toRender(
        self: ColorRepresentationState,
        format: render_types.DmabufFormat,
    ) render_types.ColorRepresentation {
        if (format.isPackedRgb()) return .{};
        const coefficients: render_types.ColorCoefficients = switch (self.coefficients orelse .bt709) {
            .identity => .identity,
            .bt601 => .bt601,
            .bt709 => .bt709,
            .bt2020 => .bt2020,
            else => unreachable,
        };
        const range: render_types.ColorRange = switch (self.range orelse .limited) {
            .full => .full,
            .limited => .limited,
            else => unreachable,
        };
        const chroma_location: render_types.ChromaLocation = switch (self.chroma_location orelse .type_0) {
            .type_0 => .type_0,
            .type_1 => .type_1,
            .type_2 => .type_2,
            .type_3 => .type_3,
            .type_4 => .type_4,
            .type_5 => .type_5,
            else => unreachable,
        };
        return .{
            .coefficients = coefficients,
            .range = range,
            .chroma_location = chroma_location,
        };
    }
};

pub const ColorRepresentationHandler = struct {
    context: *anyopaque,
    surface_destroyed: *const fn (*anyopaque) void,
    validate_commit: *const fn (
        *anyopaque,
        ColorRepresentationState,
        ?render_types.DmabufFormat,
    ) bool,
};

pub fn setColorRepresentationHandler(self: *Self, handler: ColorRepresentationHandler) error{AlreadyExists}!void {
    if (self.color_representation_handler != null) return error.AlreadyExists;
    self.color_representation_handler = handler;
}

pub fn clearColorRepresentationHandler(self: *Self, context: *anyopaque) void {
    const handler = self.color_representation_handler orelse unreachable;
    std.debug.assert(handler.context == context);
    self.color_representation_handler = null;
    self.state().pending_color_representation = .{};
}

pub fn setPendingColorRepresentation(self: *Self, value: ColorRepresentationState) void {
    std.debug.assert(self.color_representation_handler != null);
    self.state().pending_color_representation = value;
}

pub fn pendingColorRepresentation(self: *Self) ColorRepresentationState {
    return self.state().pending_color_representation;
}

pub fn currentColorRepresentation(store: *Store, id: Id) ?ColorRepresentationState {
    const surface_state = store.get(id) orelse return null;
    return surface_state.current_color_representation;
}

pub const AlphaModifierHandler = struct {
    context: *anyopaque,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub fn setAlphaModifierHandler(self: *Self, handler: AlphaModifierHandler) error{AlreadyExists}!void {
    if (self.alpha_modifier_handler != null) return error.AlreadyExists;
    self.alpha_modifier_handler = handler;
}

pub fn clearAlphaModifierHandler(self: *Self, context: *anyopaque) void {
    const handler = self.alpha_modifier_handler orelse unreachable;
    std.debug.assert(handler.context == context);
    self.alpha_modifier_handler = null;
    self.state().pending_alpha_multiplier = std.math.maxInt(u32);
}

pub fn setPendingAlphaMultiplier(self: *Self, factor: u32) void {
    std.debug.assert(self.alpha_modifier_handler != null);
    self.state().pending_alpha_multiplier = factor;
}

pub fn currentAlphaMultiplier(store: *Store, id: Id) ?u32 {
    return (store.get(id) orelse return null).current_alpha_multiplier;
}

pub const PresentationHint = wp.TearingControlV1.PresentationHint;

pub const TearingControlHandler = struct {
    context: *anyopaque,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub fn setTearingControlHandler(
    self: *Self,
    handler: TearingControlHandler,
) error{AlreadyExists}!void {
    if (self.tearing_control_handler != null) return error.AlreadyExists;
    self.tearing_control_handler = handler;
}

pub fn clearTearingControlHandler(self: *Self, context: *anyopaque) void {
    const handler = self.tearing_control_handler orelse unreachable;
    std.debug.assert(handler.context == context);
    self.tearing_control_handler = null;
    self.state().pending_presentation_hint = .vsync;
}

pub fn setPendingPresentationHint(self: *Self, hint: PresentationHint) void {
    std.debug.assert(self.tearing_control_handler != null);
    self.state().pending_presentation_hint = hint;
}

pub fn currentPresentationHint(store: *Store, id: Id) ?PresentationHint {
    const surface_state = store.get(id) orelse return null;
    return surface_state.current_presentation_hint;
}

pub const FifoHandler = struct {
    context: *anyopaque,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub fn setFifoHandler(self: *Self, handler: FifoHandler) error{AlreadyExists}!void {
    if (self.fifo_handler != null) return error.AlreadyExists;
    self.fifo_handler = handler;
}

pub fn clearFifoHandler(self: *Self, context: *anyopaque) void {
    const handler = self.fifo_handler orelse unreachable;
    std.debug.assert(handler.context == context);
    self.fifo_handler = null;
}

pub fn setPendingFifoBarrier(self: *Self) void {
    std.debug.assert(self.fifo_handler != null);
    self.state().pending_fifo_set = true;
}

pub fn setPendingFifoWait(self: *Self) void {
    std.debug.assert(self.fifo_handler != null);
    self.state().pending_fifo_wait = true;
}

pub const CommitTimerHandler = struct {
    context: *anyopaque,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub fn setCommitTimerHandler(
    self: *Self,
    handler: CommitTimerHandler,
) error{AlreadyExists}!void {
    if (self.commit_timer_handler != null) return error.AlreadyExists;
    self.commit_timer_handler = handler;
}

pub fn clearCommitTimerHandler(self: *Self, context: *anyopaque) void {
    const handler = self.commit_timer_handler orelse unreachable;
    std.debug.assert(handler.context == context);
    self.commit_timer_handler = null;
}

pub fn setPendingCommitTimestamp(
    self: *Self,
    target_nanoseconds: i96,
    ready: bool,
) error{AlreadyExists}!void {
    std.debug.assert(self.commit_timer_handler != null);
    const surface_state = self.state();
    if (surface_state.pending_commit_timestamp != null) return error.AlreadyExists;
    surface_state.pending_commit_timestamp = target_nanoseconds;
    surface_state.pending_timing_ready = ready;
}

pub const BackgroundEffectHandler = struct {
    context: *anyopaque,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub fn setBackgroundEffectHandler(
    self: *Self,
    handler: BackgroundEffectHandler,
) error{AlreadyExists}!void {
    if (self.background_effect_handler != null) return error.AlreadyExists;
    self.background_effect_handler = handler;
}

pub fn clearBackgroundEffectHandler(self: *Self) void {
    std.debug.assert(self.background_effect_handler != null);
    self.background_effect_handler = null;
    const surface_state = self.state();
    surface_state.pending_blur_region.clear();
    surface_state.pending_blur_region_changed = true;
}

pub const PendingAttachment = enum {
    none,
    null_buffer,
    dmabuf,
    unsupported,
};

pub const ExplicitSyncHandler = struct {
    context: *anyopaque,
    validate_commit: *const fn (*anyopaque, PendingAttachment) bool,
    pending_ready: *const fn (*anyopaque) bool,
    take_pending: *const fn (*anyopaque) DrmSyncobj.Commit,
    surface_destroyed: *const fn (*anyopaque) void,
};

pub fn hasExplicitSyncHandler(self: *const Self) bool {
    return self.explicit_sync_handler != null;
}

pub fn setExplicitSyncHandler(
    self: *Self,
    handler: ExplicitSyncHandler,
) error{AlreadyExists}!void {
    if (self.explicit_sync_handler != null) return error.AlreadyExists;
    self.explicit_sync_handler = handler;
}

pub fn clearExplicitSyncHandler(self: *Self, context: *anyopaque) void {
    const handler = self.explicit_sync_handler orelse unreachable;
    std.debug.assert(handler.context == context);
    self.explicit_sync_handler = null;
}

pub fn setPendingBlurRegion(self: *Self, region: ?*const Region) Region.Error!void {
    std.debug.assert(self.background_effect_handler != null);
    const surface_state = self.state();
    if (region) |value|
        try surface_state.pending_blur_region.copyFrom(value)
    else
        surface_state.pending_blur_region.clear();
    surface_state.pending_blur_region_changed = true;
}

/// The returned region is borrowed until the surface's next applied commit or
/// any store insertion that reallocates its slots.
pub fn currentBlurRegion(store: *Store, id: Id) ?*const Region {
    const surface_state = store.get(id) orelse return null;
    if (surface_state.current_blur_region.isEmpty()) return null;
    return &surface_state.current_blur_region;
}

pub const Role = enum {
    xdg_toplevel,
    xdg_popup,
    layer_surface,
    session_lock,
    subsurface,
    cursor,
    drag_icon,
    input_popup,
    xwayland,
};

pub const CommitInfo = struct {
    attachment_changed: bool,
    had_buffer: bool,
    has_buffer: bool,
    offset_x: i32,
    offset_y: i32,
};

const CachedCommit = struct {
    sequence: u64,
    role_ready: bool,
    sync_ready: bool,
    fifo_set: bool,
    fifo_wait: bool,
    fifo_wait_ignored: bool,
    target_timestamp: ?i96,
    timing_ready: bool,
    buffer: ?BufferSnapshot,
    attachment_changed: bool,
    has_buffer: bool,
    offset_x: i32,
    offset_y: i32,
    scale: i32,
    transform: wl.Output.Transform,
    viewport: ViewportState,
    content_type: ContentType,
    color_description: render_types.ColorDescription,
    color_representation: ColorRepresentationState,
    alpha_multiplier: u32,
    presentation_hint: PresentationHint,
    blur_region: Region,
    blur_region_changed: bool,
    surface_damage: Region,
    buffer_damage: Region,
    opaque_region: Region,
    input: InputRegion,

    fn deinit(self: *CachedCommit) void {
        if (self.buffer) |*buffer| buffer.deinit();
        self.surface_damage.deinit();
        self.buffer_damage.deinit();
        self.blur_region.deinit();
        self.opaque_region.deinit();
        self.input.deinit();
        self.* = undefined;
    }
};

pub const CommitAction = enum {
    apply,
    cache,
    apply_cached,
    reject,
};

/// The surface copies this table but borrows its context until `releaseRole` or
/// until the `surface_destroyed` callback returns.
pub const RoleHandler = struct {
    context: *anyopaque,
    before_commit: *const fn (*anyopaque, CommitInfo) CommitAction,
    after_commit: *const fn (*anyopaque, CommitInfo) void,
    tree_applied: ?*const fn (*anyopaque, CommitInfo) void = null,
    surface_destroyed: *const fn (*anyopaque) void,
    preferred_scale: ?*const fn (*anyopaque) ?render_types.Scale = null,
    role_tag: ?RoleTag = null,
};

pub const RoleTag = enum {
    pointer_cursor,
    tablet_tool_cursor,
};

pub const RoleIdentity = struct {
    tag: RoleTag,
    context: *anyopaque,
};

/// The surface retains this caller-owned object and its context until removal.
/// Registrations must remain unchanged during commit notifications. On surface
/// destruction, `surface_destroyed` must unregister this listener before returning.
pub const CommitListener = struct {
    context: *anyopaque,
    committed: ?*const fn (*anyopaque) void = null,
    discarded: ?*const fn (*anyopaque) void = null,
    applied: *const fn (*anyopaque) void,
    surface_destroyed: *const fn (*anyopaque) void,
};

/// The surface retains and mutates this caller-owned object until removal.
/// The object and its context must remain valid while registered. `presented`
/// and `discarded` are terminal callbacks and must unregister it before returning.
pub const CommitFeedback = struct {
    context: *anyopaque,
    sampled: *const fn (*anyopaque, *anyopaque) void,
    presented: *const fn (*anyopaque, presentation.Info) void,
    discarded: *const fn (*anyopaque) void,
    state: Status = .pending,
    cached_sequence: ?u64 = null,

    pub const Status = enum {
        pending,
        cached,
        active,
        submitted,
    };
};

pub fn reserveRole(self: *Self, role: Role, handler: RoleHandler) RoleError!void {
    const surface_state = self.state();
    if (surface_state.role) |assigned| {
        if (assigned != role) return error.AlreadyAssigned;
    }
    if (self.role_handler != null) return error.AlreadyReserved;

    self.role_handler = handler;
}

pub fn assignReservedRole(self: *Self, role: Role, context: *anyopaque) RoleError!void {
    const surface_state = self.state();
    if (surface_state.role) |assigned| {
        if (assigned != role) return error.AlreadyAssigned;
    }
    const handler = self.role_handler orelse return error.NotReserved;
    if (handler.context != context) return error.NotReserved;
    surface_state.role = role;
    if (role == .cursor) {
        surface_state.pending_input.setEmpty();
        surface_state.current_input.setEmpty();
    }
}

pub fn assignedRole(self: *Self) ?Role {
    return self.state().role;
}

pub fn roleIdentity(self: *Self, role: Role) ?RoleIdentity {
    if (self.state().role != role) return null;
    const handler = self.role_handler orelse return null;
    return .{
        .tag = handler.role_tag orelse return null,
        .context = handler.context,
    };
}

pub fn rolePreferredScale(self: *Self) ?render_types.Scale {
    const handler = self.role_handler orelse return null;
    const preferred_scale = handler.preferred_scale orelse return null;
    return preferred_scale(handler.context);
}

pub fn hasBufferAttachedOrCommitted(self: *Self) bool {
    return self.pending_attachment.hasBuffer() or self.state().has_committed_buffer;
}

pub fn hasBufferAttached(self: *Self) bool {
    return self.pending_attachment.hasBuffer() or self.state().current_buffer != null;
}

pub fn releaseRole(self: *Self, context: *anyopaque) void {
    const handler = self.role_handler orelse return;
    std.debug.assert(handler.context == context);
    self.role_handler = null;
}

pub fn addCommitListener(
    self: *Self,
    listener: *CommitListener,
) error{OutOfMemory}!void {
    std.debug.assert(!self.notifying_commit_listeners);
    for (self.commit_listeners.items) |candidate| std.debug.assert(candidate != listener);
    try self.commit_listeners.append(self.allocator, listener);
}

pub fn removeCommitListener(self: *Self, listener: *CommitListener) void {
    std.debug.assert(!self.notifying_commit_listeners);
    for (self.commit_listeners.items, 0..) |candidate, index| {
        if (candidate == listener) {
            _ = self.commit_listeners.orderedRemove(index);
            return;
        }
    }
    unreachable;
}

pub fn addCommitFeedback(self: *Self, feedback: *CommitFeedback) error{OutOfMemory}!void {
    feedback.state = .pending;
    feedback.cached_sequence = null;
    try self.state().commit_feedbacks.append(self.allocator, feedback);
}

pub fn removeCommitFeedback(store: *Store, id: Id, feedback: *CommitFeedback) void {
    const surface_state = store.get(id) orelse unreachable;
    for (surface_state.commit_feedbacks.items, 0..) |candidate, index| {
        if (candidate == feedback) {
            _ = surface_state.commit_feedbacks.orderedRemove(index);
            return;
        }
    }
    unreachable;
}

pub fn applyCachedCommit(self: *Self) void {
    markCachedReady(self, std.math.maxInt(u64), false);
}

pub fn applyCachedUpTo(self: *Self, sequence: u64) void {
    markCachedReady(self, sequence, true);
}

fn markCachedReady(self: *Self, sequence: u64, ignore_fifo_wait: bool) void {
    const surface_state = self.state();
    for (surface_state.cached_commits.items) |*cached| {
        if (cached.sequence > sequence) break;
        cached.role_ready = true;
        if (ignore_fifo_wait) cached.fifo_wait_ignored = true;
    }
    applyReadyCached(self);
}

fn applyReadyCached(self: *Self) void {
    const surface_state = self.state();
    var accumulated_damage = Region.init();
    defer accumulated_damage.deinit();
    var applied = false;
    while (surface_state.cached_commits.items.len > 0) {
        const first = surface_state.cached_commits.items[0];
        if (!first.role_ready or !first.sync_ready or
            !first.timing_ready or
            !fifoCommitReady(first.fifo_wait, first.fifo_wait_ignored, surface_state.fifo_barrier))
        {
            break;
        }
        var cached = surface_state.cached_commits.orderedRemove(0);
        applyCached(self, &cached);
        cached.deinit();
        accumulated_damage.unionWith(&surface_state.current_damage) catch {
            self.resource.postNoMemory();
            return;
        };
        applied = true;
    }
    if (applied) surface_state.current_damage.copyFrom(&accumulated_damage) catch
        self.resource.postNoMemory();
}

pub fn hasCachedCommit(self: *Self) bool {
    return self.state().cached_commits.items.len > 0;
}

pub fn latestCachedSequence(self: *Self) ?u64 {
    const cached = self.state().cached_commits.items;
    return if (cached.len == 0) null else cached[cached.len - 1].sequence;
}

pub fn discardCachedCommit(self: *Self) void {
    const surface_state = self.state();
    for (surface_state.cached_commits.items) |*cached| cached.deinit();
    surface_state.cached_commits.clearRetainingCapacity();

    notifyCommitListeners(self, .discarded);

    var index = surface_state.callbacks.items.len;
    while (index > 0) {
        index -= 1;
        const callback = surface_state.callbacks.items[index];
        if (callback.state == .cached) callback.resource.destroy();
    }
    discardCommitFeedbacks(surface_state, .cached);
}

pub fn sendFrameDone(self: *Self, time_milliseconds: u32) void {
    sendFrameDoneFor(self.store, self.id, time_milliseconds);
}

/// The returned snapshot is borrowed from the store and is invalidated by a
/// replacement commit or any store insertion that reallocates its slots.
pub fn currentBuffer(store: *Store, id: Id) ?*BufferSnapshot {
    const surface_state = store.get(id) orelse return null;
    return if (surface_state.current_buffer) |*buffer| buffer else null;
}

pub fn currentOpaqueCoversBuffer(store: *Store, id: Id) bool {
    const surface_state = store.get(id) orelse return false;
    const buffer = if (surface_state.current_buffer) |*current| current else return false;
    return surface_state.current_opaque.coversRectangle(
        0,
        0,
        buffer.logical_size.width,
        buffer.logical_size.height,
    );
}

/// The returned region is borrowed until the surface's next applied commit or
/// any store insertion that reallocates its slots.
pub fn currentOpaque(store: *Store, id: Id) ?*const Region {
    const surface_state = store.get(id) orelse return null;
    return &surface_state.current_opaque;
}

/// The returned region is borrowed until the surface's next applied commit or
/// any store insertion that reallocates its slots.
pub fn currentDamage(store: *Store, id: Id) ?*const Region {
    const surface_state = store.get(id) orelse return null;
    return &surface_state.current_damage;
}

pub fn currentDamagePrecise(store: *Store, id: Id) bool {
    const surface_state = store.get(id) orelse return false;
    return surface_state.current_damage_precise;
}

pub fn acceptsInput(store: *Store, id: Id, x: f64, y: f64) bool {
    const surface_state = store.get(id) orelse return false;
    const buffer = if (surface_state.current_buffer) |*current| current else return false;
    if (x < 0 or y < 0 or
        x >= @as(f64, @floatFromInt(buffer.logical_size.width)) or
        y >= @as(f64, @floatFromInt(buffer.logical_size.height))) return false;
    if (surface_state.current_input.infinite) return true;
    if (x > std.math.maxInt(i32) or y > std.math.maxInt(i32)) return false;
    return surface_state.current_input.value.contains(
        @intFromFloat(@floor(x)),
        @intFromFloat(@floor(y)),
    );
}

pub fn copyCurrentInputRegion(store: *Store, id: Id, destination: *Region) Region.Error!void {
    destination.clear();
    const surface_state = store.get(id) orelse return;
    const buffer = surface_state.current_buffer orelse return;
    try destination.add(
        0,
        0,
        @intCast(buffer.logical_size.width),
        @intCast(buffer.logical_size.height),
    );
    if (!surface_state.current_input.infinite) {
        try destination.intersectWith(&surface_state.current_input.value);
    }
}

pub fn sendFrameDoneFor(store: *Store, id: Id, time_milliseconds: u32) void {
    const surface_state = store.get(id) orelse return;
    while (true) {
        const callback = for (surface_state.callbacks.items) |candidate| {
            if (candidate.state == .submitted) break candidate;
        } else return;

        callback.resource.destroySendDone(time_milliseconds);
    }
}

pub fn hasCallbackOnlyFrameCallback(store: *Store, id: Id) bool {
    const surface_state = store.get(id) orelse return false;
    for (surface_state.callbacks.items) |callback| {
        if (callback.state == .active and callback.callback_only) return true;
    }
    return false;
}

pub fn sendCallbackOnlyFrameDoneFor(store: *Store, id: Id, time_milliseconds: u32) bool {
    const surface_state = store.get(id) orelse return false;
    var sent = false;
    while (true) {
        const callback = for (surface_state.callbacks.items) |candidate| {
            if (candidate.state == .active or candidate.state == .submitted) break candidate;
        } else return sent;
        if (callback.state == .submitted or !callback.callback_only) return sent;

        callback.resource.destroySendDone(time_milliseconds);
        sent = true;
    }
}

pub fn setPreferredBufferScale(store: *Store, id: Id, scale: u32) void {
    std.debug.assert(scale > 0 and scale <= std.math.maxInt(i32));
    const surface_state = store.get(id) orelse return;
    const resource = surface_state.resource;
    if (resource.getVersion() < wl.Surface.preferred_buffer_scale_since_version) return;
    const scale_value: i32 = @intCast(scale);
    if (surface_state.preferred_buffer_scale == scale_value) return;
    surface_state.preferred_buffer_scale = scale_value;
    resource.sendPreferredBufferScale(scale_value);
    resource.sendPreferredBufferTransform(.normal);
}

pub fn submitPresentationFor(store: *Store, id: Id, output_context: *anyopaque) void {
    const surface_state = store.get(id) orelse return;
    if (surface_state.presentation_output != null) return;
    surface_state.presentation_output = output_context;
    surface_state.commit_after_submission = false;
    for (surface_state.callbacks.items) |callback| {
        if (callback.state == .active) callback.state = .submitted;
    }
    for (surface_state.commit_feedbacks.items) |feedback| {
        if (feedback.state == .active) {
            feedback.sampled(feedback.context, output_context);
            feedback.state = .submitted;
        }
    }
}

pub fn markFifoBarrierVisible(store: *Store, id: Id, output_context: *anyopaque) void {
    const surface_state = store.get(id) orelse return;
    if (!surface_state.fifo_barrier or surface_state.fifo_barrier_output != null) return;
    surface_state.fifo_barrier_output = output_context;
}

pub fn hasFifoBarrierForOutput(store: *Store, output_context: *anyopaque) bool {
    var surfaces = store.iterator();
    while (surfaces.next()) |entry| {
        if (entry.value.fifo_barrier and
            entry.value.fifo_barrier_output == output_context) return true;
    }
    return false;
}

pub fn clearFifoBarriersForOutput(store: *Store, output_context: *anyopaque) void {
    var surfaces = store.iterator();
    while (surfaces.next()) |entry| {
        const surface_state = entry.value;
        if (!surface_state.fifo_barrier or
            surface_state.fifo_barrier_output != output_context) continue;
        surface_state.fifo_barrier = false;
        surface_state.fifo_barrier_output = null;
        applyReadyCached(Self.fromResource(surface_state.resource));
    }
}

pub fn releaseTimedCommits(store: *Store, now_nanoseconds: i96) void {
    var surfaces = store.iterator();
    while (surfaces.next()) |entry| {
        const surface_state = entry.value;
        if (releaseTimedCommitState(surface_state, now_nanoseconds)) {
            applyReadyCached(Self.fromResource(surface_state.resource));
        }
    }
}

fn releaseTimedCommitState(surface_state: *State, now_nanoseconds: i96) bool {
    var cached_changed = false;
    if (surface_state.pending_commit_timestamp) |target| {
        if (!surface_state.pending_timing_ready and target <= now_nanoseconds) {
            surface_state.pending_timing_ready = true;
        }
    }
    for (surface_state.cached_commits.items) |*cached| {
        const target = cached.target_timestamp orelse continue;
        if (cached.timing_ready or target > now_nanoseconds) continue;
        cached.timing_ready = true;
        cached_changed = true;
    }
    return cached_changed;
}

pub fn earliestCommitTimestamp(store: *Store) ?i96 {
    var earliest: ?i96 = null;
    var surfaces = store.iterator();
    while (surfaces.next()) |entry| {
        const surface_state = entry.value;
        if (!surface_state.pending_timing_ready) {
            if (surface_state.pending_commit_timestamp) |target| {
                earliest = if (earliest) |current| @min(current, target) else target;
            }
        }
        for (surface_state.cached_commits.items) |cached| {
            if (cached.timing_ready) continue;
            const target = cached.target_timestamp orelse continue;
            earliest = if (earliest) |current| @min(current, target) else target;
        }
    }
    return earliest;
}

pub fn discardUnsubmittedFeedback(store: *Store) void {
    var surfaces = store.iterator();
    while (surfaces.next()) |entry| {
        if (entry.value.presentation_output == null) {
            discardCommitFeedbacks(entry.value, .active);
        }
    }
}

pub fn sendSubmittedFrameCallbacks(
    store: *Store,
    output_context: *anyopaque,
    time_milliseconds: u32,
) void {
    var surfaces = store.iterator();
    while (surfaces.next()) |entry| {
        if (entry.value.presentation_output != output_context) continue;
        sendFrameDoneFor(store, entry.id, time_milliseconds);
    }
}

pub fn finishPresentation(
    store: *Store,
    output_context: *anyopaque,
    info: presentation.Info,
) void {
    var surfaces = store.iterator();
    while (surfaces.next()) |entry| {
        const surface_state = entry.value;
        if (surface_state.presentation_output != output_context) continue;
        surface_state.presentation_output = null;
        surface_state.commit_after_submission = false;
        while (commitFeedbackWithState(surface_state, .submitted)) |feedback| {
            feedback.presented(feedback.context, info);
        }
    }
}

pub fn discardPresentation(store: *Store, output_context: *anyopaque) void {
    var surfaces = store.iterator();
    while (surfaces.next()) |entry| {
        const surface_state = entry.value;
        if (surface_state.presentation_output != output_context) continue;
        surface_state.presentation_output = null;
        for (surface_state.callbacks.items) |callback| {
            if (callback.state == .submitted) callback.state = .active;
        }
        if (surface_state.commit_after_submission) {
            discardCommitFeedbacks(surface_state, .submitted);
        } else {
            setCommitFeedbackState(surface_state, .submitted, .active);
        }
        surface_state.commit_after_submission = false;
    }
}

fn handleRequest(resource: *wl.Surface, request: wl.Surface.Request, self: *Self) void {
    const surface_state = self.state();
    switch (request) {
        .destroy => resource.destroy(),
        .attach => |attach| {
            if (resource.getVersion() >= 5 and (attach.x != 0 or attach.y != 0)) {
                resource.postError(.invalid_offset, "attach offset requires wl_surface.offset");
                return;
            }
            self.pending_attachment.set(attach.buffer) catch {
                resource.getClient().postImplementationError("unsupported wl_buffer type");
                return;
            };
            self.has_pending_attachment = true;
            if (resource.getVersion() < 5) {
                surface_state.pending_offset_x = attach.x;
                surface_state.pending_offset_y = attach.y;
            }
        },
        .damage => |damage| surface_state.pending_surface_damage.add(
            damage.x,
            damage.y,
            damage.width,
            damage.height,
        ) catch resource.postNoMemory(),
        .frame => |frame| createFrameCallback(self, frame.callback) catch
            resource.postNoMemory(),
        .set_opaque_region => |set| {
            if (set.region) |region_resource| {
                const region = WaylandRegion.fromResource(region_resource);
                surface_state.pending_opaque.copyFrom(&region.value) catch {
                    resource.postNoMemory();
                    return;
                };
            } else {
                surface_state.pending_opaque.clear();
            }
        },
        .set_input_region => |set| {
            if (surface_state.role == .cursor) return;
            if (set.region) |region_resource| {
                const region = WaylandRegion.fromResource(region_resource);
                surface_state.pending_input.set(&region.value) catch {
                    resource.postNoMemory();
                    return;
                };
            } else {
                surface_state.pending_input.setInfinite();
            }
        },
        .commit => commit(self),
        .set_buffer_transform => |set| {
            if (!surface_geometry.validTransform(set.transform)) {
                resource.postError(.invalid_transform, "invalid buffer transform");
                return;
            }
            surface_state.pending_transform = set.transform;
        },
        .set_buffer_scale => |set| {
            if (set.scale <= 0) {
                resource.postError(.invalid_scale, "buffer scale must be positive");
                return;
            }
            surface_state.pending_scale = set.scale;
        },
        .damage_buffer => |damage| surface_state.pending_buffer_damage.add(
            damage.x,
            damage.y,
            damage.width,
            damage.height,
        ) catch resource.postNoMemory(),
        .offset => |offset| {
            surface_state.pending_offset_x = offset.x;
            surface_state.pending_offset_y = offset.y;
        },
        .get_release => |release| createBufferReleaseCallback(self, release.callback) catch
            resource.postNoMemory(),
    }
}

fn commit(self: *Self) void {
    const surface_state = self.state();
    const has_unassociated_release = for (surface_state.release_callbacks.items) |callback| {
        if (callback.generation == null) break true;
    } else false;
    if (has_unassociated_release and
        (!self.has_pending_attachment or !self.pending_attachment.hasBuffer()))
    {
        self.resource.postError(
            .no_buffer,
            "wl_surface.get_release requires a non-null buffer attachment",
        );
        return;
    }

    const attachment = pendingAttachment(self);
    const acquire_ready = if (self.explicit_sync_handler) |handler| ready: {
        if (!handler.validate_commit(handler.context, attachment)) return;
        break :ready attachment != .dmabuf or handler.pending_ready(handler.context);
    } else true;
    const fifo_ready = fifoCommitReady(
        surface_state.pending_fifo_wait,
        false,
        surface_state.fifo_barrier,
    );
    const timing_ready = surface_state.pending_timing_ready;

    const commit_info = pendingCommitInfo(self);
    if (self.color_representation_handler) |handler| {
        if (!handler.validate_commit(
            handler.context,
            surface_state.pending_color_representation,
            effectiveBufferFormat(self),
        )) return;
    }
    const action = if (self.role_handler) |handler|
        handler.before_commit(handler.context, commit_info)
    else
        CommitAction.apply;

    switch (action) {
        .apply => {
            if (!acquire_ready or !fifo_ready or !timing_ready or self.hasCachedCommit()) {
                if (cachePending(self, true)) {
                    notifyCommitted(self);
                    applyReadyCached(self);
                }
            } else {
                notifyCommitted(self);
                applyPending(self, commit_info);
            }
        },
        .cache => if (cachePending(self, false)) notifyCommitted(self),
        .apply_cached => {
            if (cachePending(self, true)) {
                notifyCommitted(self);
                applyCachedCommit(self);
            }
        },
        .reject => discardCommitFeedbacks(self.state(), .pending),
    }
}

fn pendingAttachment(self: *const Self) PendingAttachment {
    if (!self.has_pending_attachment) return .none;
    if (!self.pending_attachment.hasBuffer()) return .null_buffer;
    if (self.pending_attachment.dmabuf != null) return .dmabuf;
    return .unsupported;
}

fn notifyCommitted(self: *Self) void {
    notifyCommitListeners(self, .committed);
}

const CommitNotification = enum { committed, discarded, applied };

fn notifyCommitListeners(self: *Self, notification: CommitNotification) void {
    std.debug.assert(!self.notifying_commit_listeners);
    self.notifying_commit_listeners = true;
    defer self.notifying_commit_listeners = false;
    for (self.commit_listeners.items) |listener| switch (notification) {
        .committed => if (listener.committed) |committed| committed(listener.context),
        .discarded => if (listener.discarded) |discarded| discarded(listener.context),
        .applied => listener.applied(listener.context),
    };
}

fn pendingCommitInfo(self: *Self) CommitInfo {
    const surface_state = self.state();
    return .{
        .attachment_changed = self.has_pending_attachment,
        .had_buffer = surface_state.current_buffer != null,
        .has_buffer = if (self.has_pending_attachment)
            self.pending_attachment.hasBuffer()
        else if (surface_state.cached_commits.getLastOrNull()) |cached|
            cached.has_buffer
        else
            surface_state.current_buffer != null,
        .offset_x = surface_state.pending_offset_x,
        .offset_y = surface_state.pending_offset_y,
    };
}

fn effectiveBufferFormat(self: *Self) ?render_types.DmabufFormat {
    if (self.has_pending_attachment) {
        if (self.pending_attachment.dmabuf) |buffer| {
            return render_types.DmabufFormat.fromFourcc(buffer.format()).?;
        }
        return if (self.pending_attachment.hasBuffer()) .argb8888 else null;
    }
    const cached_commits = self.state().cached_commits.items;
    var index = cached_commits.len;
    while (index > 0) {
        index -= 1;
        const cached = &cached_commits[index];
        if (!cached.attachment_changed) continue;
        return if (cached.buffer) |*buffer| buffer.bufferFormat() else null;
    }
    return if (self.state().current_buffer) |*buffer| buffer.bufferFormat() else null;
}

fn applyPending(self: *Self, commit_info: CommitInfo) void {
    const surface_state = self.state();
    var applied_info = commit_info;
    const previous_geometry = currentBufferGeometry(surface_state);
    const offset_changed = surface_state.pending_offset_x != 0 or
        surface_state.pending_offset_y != 0;

    surface_state.current_blur_region.copyFrom(&surface_state.pending_blur_region) catch {
        self.resource.postNoMemory();
        return;
    };
    surface_state.current_opaque.copyFrom(&surface_state.pending_opaque) catch {
        self.resource.postNoMemory();
        return;
    };
    surface_state.current_input.copyFrom(&surface_state.pending_input) catch {
        self.resource.postNoMemory();
        return;
    };

    if (self.has_pending_attachment) {
        const reusable = if (surface_state.current_buffer) |*current| current else null;
        const snapshot = snapshotPendingAttachment(self, reusable) catch |err| switch (err) {
            error.ImportFailed => failed: {
                log.warn("DMA-BUF became unavailable after successful import", .{});
                applied_info.has_buffer = false;
                break :failed null;
            },
            else => {
                postBufferError(self, err);
                return;
            },
        };

        const retains_client_buffer = if (snapshot) |value| value.retainsClientBuffer() else false;
        if (surface_state.current_buffer) |*current| current.deinit();
        surface_state.current_buffer = snapshot;

        releasePendingAttachment(self, retains_client_buffer);
    } else if (surface_state.current_buffer) |*current| {
        current.updateGeometry(
            surface_state.pending_scale,
            surface_state.pending_transform,
            surface_state.pending_viewport,
            surface_state.role == .cursor,
        ) catch |err| {
            postBufferError(self, err);
            return;
        };
        current.color_description = surface_state.pending_color_description;
        current.color_representation = surface_state.pending_color_representation.toRender(
            current.bufferFormat(),
        );
    }

    surface_state.current_scale = surface_state.pending_scale;
    surface_state.current_transform = surface_state.pending_transform;
    surface_state.current_viewport = surface_state.pending_viewport;
    surface_state.current_content_type = surface_state.pending_content_type;
    const color_description_changed = !std.meta.eql(
        surface_state.current_color_description,
        surface_state.pending_color_description,
    );
    const color_representation_changed = !std.meta.eql(
        surface_state.current_color_representation,
        surface_state.pending_color_representation,
    );
    surface_state.current_color_description = surface_state.pending_color_description;
    surface_state.current_color_representation = surface_state.pending_color_representation;
    const alpha_changed = surface_state.current_alpha_multiplier != surface_state.pending_alpha_multiplier;
    surface_state.current_alpha_multiplier = surface_state.pending_alpha_multiplier;
    surface_state.current_presentation_hint = surface_state.pending_presentation_hint;
    surface_state.current_offset_x = surface_state.pending_offset_x;
    surface_state.current_offset_y = surface_state.pending_offset_y;
    updateCurrentDamage(
        surface_state,
        previous_geometry,
        &surface_state.pending_surface_damage,
        &surface_state.pending_buffer_damage,
        offset_changed,
    );
    if (alpha_changed) surface_state.current_damage_precise = false;
    if (color_description_changed) surface_state.current_damage_precise = false;
    if (color_representation_changed) surface_state.current_damage_precise = false;
    if (surface_state.pending_blur_region_changed) {
        surface_state.current_damage_precise = false;
    }
    const callback_only = currentCommitIsCallbackOnly(surface_state);
    surface_state.pending_offset_x = 0;
    surface_state.pending_offset_y = 0;
    applyFifoSet(surface_state, surface_state.pending_fifo_set);
    surface_state.pending_fifo_set = false;
    surface_state.pending_fifo_wait = false;
    surface_state.pending_commit_timestamp = null;
    surface_state.pending_timing_ready = true;
    surface_state.pending_blur_region_changed = false;
    surface_state.pending_surface_damage.clear();
    surface_state.pending_buffer_damage.clear();
    surface_state.has_committed = true;
    if (applied_info.has_buffer) surface_state.has_committed_buffer = true;
    if (surface_state.presentation_output != null) surface_state.commit_after_submission = true;
    discardCommitFeedbacks(surface_state, .active);
    for (surface_state.callbacks.items) |callback| {
        if (callback.state == .pending) {
            callback.state = .active;
            callback.callback_only = callback_only;
        }
    }
    if (applied_info.has_buffer) {
        setCommitFeedbackState(surface_state, .pending, .active);
    } else {
        discardCommitFeedbacks(surface_state, .pending);
    }

    finishApplied(self, applied_info);
}

fn cachePending(self: *Self, role_ready: bool) bool {
    const surface_state = self.state();
    var snapshot: ?BufferSnapshot = null;
    defer if (snapshot) |*buffer| buffer.deinit();

    if (self.has_pending_attachment) {
        snapshot = snapshotPendingAttachment(self, null) catch |err| switch (err) {
            error.ImportFailed => failed: {
                log.warn("DMA-BUF became unavailable after successful import", .{});
                break :failed null;
            },
            else => {
                postBufferError(self, err);
                return false;
            },
        };
    } else {
        const buffer = latestEffectiveBuffer(surface_state);
        if (buffer) |existing| {
            _ = surface_geometry.calculate(
                existing.buffer_size,
                surface_state.pending_scale,
                surface_state.pending_transform,
                surface_state.pending_viewport,
                surface_state.role == .cursor,
            ) catch |err| {
                postBufferError(self, err);
                return false;
            };
        }
    }

    const sequence = surface_state.next_cached_sequence;
    var cached: CachedCommit = .{
        .sequence = sequence,
        .role_ready = role_ready,
        .sync_ready = if (snapshot) |*buffer| buffer.isReady() else true,
        .fifo_set = surface_state.pending_fifo_set,
        .fifo_wait = surface_state.pending_fifo_wait,
        .fifo_wait_ignored = false,
        .target_timestamp = surface_state.pending_commit_timestamp,
        .timing_ready = surface_state.pending_timing_ready,
        .buffer = snapshot,
        .attachment_changed = self.has_pending_attachment,
        .has_buffer = if (self.has_pending_attachment)
            snapshot != null
        else if (surface_state.cached_commits.getLastOrNull()) |previous|
            previous.has_buffer
        else
            surface_state.current_buffer != null,
        .offset_x = surface_state.pending_offset_x,
        .offset_y = surface_state.pending_offset_y,
        .scale = surface_state.pending_scale,
        .transform = surface_state.pending_transform,
        .viewport = surface_state.pending_viewport,
        .content_type = surface_state.pending_content_type,
        .color_description = surface_state.pending_color_description,
        .color_representation = surface_state.pending_color_representation,
        .alpha_multiplier = surface_state.pending_alpha_multiplier,
        .presentation_hint = surface_state.pending_presentation_hint,
        .blur_region = Region.init(),
        .blur_region_changed = surface_state.pending_blur_region_changed,
        .surface_damage = Region.init(),
        .buffer_damage = Region.init(),
        .opaque_region = Region.init(),
        .input = InputRegion.init(),
    };
    snapshot = null;
    var cached_owned = false;
    defer if (!cached_owned) cached.deinit();

    cached.blur_region.copyFrom(&surface_state.pending_blur_region) catch {
        self.resource.postNoMemory();
        return false;
    };
    cached.opaque_region.copyFrom(&surface_state.pending_opaque) catch {
        self.resource.postNoMemory();
        return false;
    };
    cached.input.copyFrom(&surface_state.pending_input) catch {
        self.resource.postNoMemory();
        return false;
    };
    cached.surface_damage.copyFrom(&surface_state.pending_surface_damage) catch {
        self.resource.postNoMemory();
        return false;
    };
    cached.buffer_damage.copyFrom(&surface_state.pending_buffer_damage) catch {
        self.resource.postNoMemory();
        return false;
    };
    surface_state.cached_commits.append(self.allocator, cached) catch {
        self.resource.postNoMemory();
        return false;
    };
    cached_owned = true;
    surface_state.next_cached_sequence +%= 1;

    const stored = &surface_state.cached_commits.items[surface_state.cached_commits.items.len - 1];
    if (!stored.sync_ready) {
        stored.buffer.?.dmabuf.?.setAcquireReadyTarget(self.store, self.id, sequence);
    }

    if (self.has_pending_attachment) {
        const retains_client_buffer = if (cached.buffer) |value| value.retainsClientBuffer() else false;
        releasePendingAttachment(self, retains_client_buffer);
    }

    surface_state.pending_offset_x = 0;
    surface_state.pending_offset_y = 0;
    surface_state.pending_fifo_set = false;
    surface_state.pending_fifo_wait = false;
    surface_state.pending_commit_timestamp = null;
    surface_state.pending_timing_ready = true;
    surface_state.pending_blur_region_changed = false;
    surface_state.pending_surface_damage.clear();
    surface_state.pending_buffer_damage.clear();
    surface_state.has_committed = true;
    if (cached.has_buffer) surface_state.has_committed_buffer = true;
    for (surface_state.callbacks.items) |callback| {
        if (callback.state == .pending) {
            callback.state = .cached;
            callback.cached_sequence = sequence;
        }
    }
    setCommitFeedbackCached(surface_state, sequence);
    return true;
}

fn latestEffectiveBuffer(surface_state: *State) ?*BufferSnapshot {
    var index = surface_state.cached_commits.items.len;
    while (index > 0) {
        index -= 1;
        const cached = &surface_state.cached_commits.items[index];
        if (cached.attachment_changed) return if (cached.buffer) |*buffer| buffer else null;
    }
    return if (surface_state.current_buffer) |*buffer| buffer else null;
}

fn applyCached(self: *Self, cached: *CachedCommit) void {
    const surface_state = self.state();
    const previous_geometry = currentBufferGeometry(surface_state);
    const offset_changed = cached.offset_x != 0 or cached.offset_y != 0;
    const commit_info: CommitInfo = .{
        .attachment_changed = cached.attachment_changed,
        .had_buffer = surface_state.current_buffer != null,
        .has_buffer = cached.has_buffer,
        .offset_x = cached.offset_x,
        .offset_y = cached.offset_y,
    };

    surface_state.current_blur_region.copyFrom(&cached.blur_region) catch {
        self.resource.postNoMemory();
        return;
    };
    surface_state.current_opaque.copyFrom(&cached.opaque_region) catch {
        self.resource.postNoMemory();
        return;
    };
    surface_state.current_input.copyFrom(&cached.input) catch {
        self.resource.postNoMemory();
        return;
    };

    if (cached.attachment_changed) {
        if (surface_state.current_buffer) |*current| current.deinit();
        surface_state.current_buffer = cached.buffer;
        cached.buffer = null;
    }
    if (surface_state.current_buffer) |*current| {
        current.updateGeometry(
            cached.scale,
            cached.transform,
            cached.viewport,
            surface_state.role == .cursor,
        ) catch unreachable;
        current.color_description = cached.color_description;
        current.color_representation = cached.color_representation.toRender(current.bufferFormat());
    }

    surface_state.current_scale = cached.scale;
    surface_state.current_transform = cached.transform;
    surface_state.current_viewport = cached.viewport;
    surface_state.current_content_type = cached.content_type;
    const color_description_changed = !std.meta.eql(
        surface_state.current_color_description,
        cached.color_description,
    );
    const color_representation_changed = !std.meta.eql(
        surface_state.current_color_representation,
        cached.color_representation,
    );
    surface_state.current_color_description = cached.color_description;
    surface_state.current_color_representation = cached.color_representation;
    const alpha_changed = surface_state.current_alpha_multiplier != cached.alpha_multiplier;
    surface_state.current_alpha_multiplier = cached.alpha_multiplier;
    surface_state.current_presentation_hint = cached.presentation_hint;
    surface_state.current_offset_x = cached.offset_x;
    surface_state.current_offset_y = cached.offset_y;
    updateCurrentDamage(
        surface_state,
        previous_geometry,
        &cached.surface_damage,
        &cached.buffer_damage,
        offset_changed,
    );
    if (alpha_changed) surface_state.current_damage_precise = false;
    if (color_description_changed) surface_state.current_damage_precise = false;
    if (color_representation_changed) surface_state.current_damage_precise = false;
    if (cached.blur_region_changed) surface_state.current_damage_precise = false;
    const callback_only = currentCommitIsCallbackOnly(surface_state);
    applyFifoSet(surface_state, cached.fifo_set);
    if (surface_state.presentation_output != null) surface_state.commit_after_submission = true;
    discardCommitFeedbacks(surface_state, .active);
    for (surface_state.callbacks.items) |callback| {
        if (callback.state == .cached and callback.cached_sequence == cached.sequence) {
            callback.state = .active;
            callback.cached_sequence = null;
            callback.callback_only = callback_only;
        }
    }
    if (commit_info.has_buffer) {
        activateCommitFeedbacksForSequence(surface_state, cached.sequence);
    } else {
        discardCommitFeedbacksForSequence(surface_state, cached.sequence);
    }

    finishApplied(self, commit_info);
}

fn postBufferError(self: *Self, err: BufferSnapshot.Error) void {
    switch (err) {
        error.OutOfMemory => self.resource.postNoMemory(),
        error.InvalidSize => self.resource.postError(
            .invalid_size,
            "buffer dimensions are incompatible with surface state",
        ),
        error.InvalidBuffer => self.resource.getClient().postImplementationError(
            "invalid shared-memory buffer",
        ),
        error.BadViewportSize => if (self.viewport_handler) |handler|
            handler.resource.postError(.bad_size, "viewport source size must be integral")
        else
            self.resource.getClient().postImplementationError("viewport object is missing"),
        error.ViewportOutOfBuffer => if (self.viewport_handler) |handler|
            handler.resource.postError(.out_of_buffer, "viewport source exceeds the buffer")
        else
            self.resource.getClient().postImplementationError("viewport object is missing"),
        error.ImportFailed => unreachable,
    }
}

fn snapshotPendingAttachment(
    self: *Self,
    reusable: ?*BufferSnapshot,
) BufferSnapshot.Error!?BufferSnapshot {
    const surface_state = self.state();
    const allow_non_divisible_scale = surface_state.role == .cursor;
    const source_cache: render_types.SourceCache = .{
        .id = surface_state.source_cache_id,
        .version = surface_state.next_source_version,
    };
    var snapshot = if (self.pending_attachment.shm) |shm_buffer|
        try BufferSnapshot.copyShm(
            self.allocator,
            shm_buffer,
            surface_state.pending_scale,
            surface_state.pending_transform,
            surface_state.pending_viewport,
            allow_non_divisible_scale,
            reusable,
            &surface_state.pending_surface_damage,
            &surface_state.pending_buffer_damage,
            source_cache,
        )
    else if (self.pending_attachment.dmabuf) |dmabuf_buffer|
        try BufferSnapshot.retainDmabuf(
            dmabuf_buffer,
            surface_state.pending_scale,
            surface_state.pending_transform,
            surface_state.pending_viewport,
            allow_non_divisible_scale,
            if (self.explicit_sync_handler) |handler|
                handler.take_pending(handler.context)
            else
                null,
        )
    else if (self.pending_attachment.single_pixel) |pixel|
        try BufferSnapshot.copySinglePixel(
            self.allocator,
            pixel,
            surface_state.pending_scale,
            surface_state.pending_transform,
            surface_state.pending_viewport,
            allow_non_divisible_scale,
            reusable,
            source_cache,
        )
    else
        return null;
    snapshot.color_description = surface_state.pending_color_description;
    snapshot.color_representation = surface_state.pending_color_representation.toRender(
        snapshot.bufferFormat(),
    );
    if (snapshot.retainsClientBuffer()) {
        const generation = surface_state.next_release_generation;
        surface_state.next_release_generation +%= 1;
        for (surface_state.release_callbacks.items) |callback| {
            if (callback.generation == null) callback.generation = generation;
        }
        snapshot.dmabuf.?.setRelease(self.store, self.id, generation);
    } else {
        surface_state.next_source_version +%= 1;
    }
    return snapshot;
}

fn finishApplied(self: *Self, commit_info: CommitInfo) void {
    if (self.role_handler) |handler| handler.after_commit(handler.context, commit_info);

    notifyCommitListeners(self, .applied);

    if (self.role_handler) |handler| {
        if (handler.tree_applied) |tree_applied| tree_applied(handler.context, commit_info);
    }
}

fn releasePendingAttachment(self: *Self, retained: bool) void {
    std.debug.assert(self.has_pending_attachment);
    if (!retained) {
        // SHM storage is no longer used once its pixels have been copied, even
        // when the resulting content update remains cached by a synchronized role.
        if (self.pending_attachment.resource) |buffer| buffer.sendRelease();
    }
    self.pending_attachment.clear();
    self.has_pending_attachment = false;

    if (!retained) finishBufferReleaseCallbacks(self.store, self.id, null);
}

fn finishBufferReleaseCallbacks(store: *Store, surface_id: Id, generation: ?u64) void {
    const surface_state = store.get(surface_id) orelse return;
    var index: usize = 0;
    while (index < surface_state.release_callbacks.items.len) {
        const callback = surface_state.release_callbacks.items[index];
        if (callback.generation != generation) {
            index += 1;
            continue;
        }
        callback.resource.destroySendDone(0);
    }
}

fn commitFeedbackWithState(
    surface_state: *State,
    target_status: CommitFeedback.Status,
) ?*CommitFeedback {
    for (surface_state.commit_feedbacks.items) |feedback| {
        if (feedback.state == target_status) return feedback;
    }
    return null;
}

fn discardCommitFeedbacks(surface_state: *State, target_status: CommitFeedback.Status) void {
    while (commitFeedbackWithState(surface_state, target_status)) |feedback| {
        feedback.discarded(feedback.context);
    }
}

fn setCommitFeedbackState(
    surface_state: *State,
    from: CommitFeedback.Status,
    to: CommitFeedback.Status,
) void {
    for (surface_state.commit_feedbacks.items) |feedback| {
        if (feedback.state == from) {
            feedback.state = to;
            if (to != .cached) feedback.cached_sequence = null;
        }
    }
}

fn setCommitFeedbackCached(surface_state: *State, sequence: u64) void {
    for (surface_state.commit_feedbacks.items) |feedback| {
        if (feedback.state != .pending) continue;
        feedback.state = .cached;
        feedback.cached_sequence = sequence;
    }
}

fn activateCommitFeedbacksForSequence(surface_state: *State, sequence: u64) void {
    for (surface_state.commit_feedbacks.items) |feedback| {
        if (feedback.state != .cached or feedback.cached_sequence != sequence) continue;
        feedback.state = .active;
        feedback.cached_sequence = null;
    }
}

fn discardCommitFeedbacksForSequence(surface_state: *State, sequence: u64) void {
    while (true) {
        const feedback = for (surface_state.commit_feedbacks.items) |candidate| {
            if (candidate.state == .cached and candidate.cached_sequence == sequence) {
                break candidate;
            }
        } else return;
        feedback.discarded(feedback.context);
    }
}

fn handleDestroy(_: *wl.Surface, self: *Self) void {
    self.pending_attachment.clear();
    if (self.role_handler) |handler| handler.surface_destroyed(handler.context);
    if (self.viewport_handler) |handler| {
        self.viewport_handler = null;
        handler.surface_destroyed(handler.context);
    }
    if (self.content_type_handler) |handler| {
        self.content_type_handler = null;
        handler.surface_destroyed(handler.context);
    }
    if (self.color_representation_handler) |handler| {
        self.color_representation_handler = null;
        handler.surface_destroyed(handler.context);
    }
    if (self.alpha_modifier_handler) |handler| {
        self.alpha_modifier_handler = null;
        handler.surface_destroyed(handler.context);
    }
    if (self.tearing_control_handler) |handler| {
        self.tearing_control_handler = null;
        handler.surface_destroyed(handler.context);
    }
    if (self.fifo_handler) |handler| {
        self.fifo_handler = null;
        handler.surface_destroyed(handler.context);
    }
    if (self.commit_timer_handler) |handler| {
        self.commit_timer_handler = null;
        handler.surface_destroyed(handler.context);
    }
    if (self.background_effect_handler) |handler| {
        self.background_effect_handler = null;
        handler.surface_destroyed(handler.context);
    }
    if (self.explicit_sync_handler) |handler| {
        self.explicit_sync_handler = null;
        handler.surface_destroyed(handler.context);
    }
    while (self.commit_listeners.items.len > 0) {
        const previous_len = self.commit_listeners.items.len;
        self.commit_listeners.items[previous_len - 1].surface_destroyed(
            self.commit_listeners.items[previous_len - 1].context,
        );
        std.debug.assert(self.commit_listeners.items.len < previous_len);
    }
    self.commit_listeners.deinit(self.allocator);
    const surface_state = self.state();

    while (surface_state.callbacks.items.len > 0) {
        surface_state.callbacks.items[surface_state.callbacks.items.len - 1].resource.destroy();
    }
    while (surface_state.release_callbacks.items.len > 0) {
        surface_state.release_callbacks.items[surface_state.release_callbacks.items.len - 1]
            .resource.destroy();
    }
    while (surface_state.commit_feedbacks.items.len > 0) {
        const feedback = surface_state.commit_feedbacks.items[surface_state.commit_feedbacks.items.len - 1];
        feedback.discarded(feedback.context);
    }

    var removed = self.store.remove(self.id) orelse unreachable;
    removed.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn applyFifoSet(surface_state: *State, set_barrier: bool) void {
    if (!set_barrier) return;
    surface_state.fifo_barrier = true;
    surface_state.fifo_barrier_output = null;
}

fn fifoCommitReady(wait_barrier: bool, wait_ignored: bool, barrier: bool) bool {
    return !wait_barrier or wait_ignored or !barrier;
}

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

    fn setEmpty(self: *InputRegion) void {
        self.value.clear();
        self.infinite = false;
    }

    fn copyFrom(self: *InputRegion, other: *const InputRegion) Region.Error!void {
        try self.value.copyFrom(&other.value);
        self.infinite = other.infinite;
    }
};

const Attachment = struct {
    resource: ?*wl.Buffer = null,
    shm: ?*wl.shm.Buffer = null,
    dmabuf: ?*LinuxDmabuf.Buffer = null,
    single_pixel: ?u32 = null,
    destroy_listener: wl.Listener(*wl.Resource) = undefined,

    const Error = error{UnsupportedBuffer};

    fn set(self: *Attachment, resource: ?*wl.Buffer) Error!void {
        self.clear();
        const buffer = resource orelse return;
        const shm_buffer = wl.shm.Buffer.get(@ptrCast(buffer));
        const dmabuf_buffer = if (shm_buffer == null)
            LinuxDmabuf.Buffer.fromResource(buffer)
        else
            null;
        const single_pixel_buffer = if (shm_buffer == null and dmabuf_buffer == null)
            SinglePixelBuffer.Buffer.fromResource(buffer)
        else
            null;
        if (shm_buffer == null and dmabuf_buffer == null and single_pixel_buffer == null) {
            return error.UnsupportedBuffer;
        }

        self.resource = buffer;
        self.shm = if (shm_buffer) |shm| wl_shm_buffer_ref(shm) else null;
        self.dmabuf = dmabuf_buffer;
        if (dmabuf_buffer) |dmabuf| dmabuf.reference();
        self.single_pixel = if (single_pixel_buffer) |single| single.pixel else null;
        self.destroy_listener = wl.Listener(*wl.Resource).init(handleResourceDestroy);
        @as(*wl.Resource, @ptrCast(buffer)).addDestroyListener(&self.destroy_listener);
    }

    fn clear(self: *Attachment) void {
        if (self.resource != null) self.destroy_listener.link.remove();
        if (self.shm) |buffer| wl_shm_buffer_unref(buffer);
        if (self.dmabuf) |buffer| buffer.unreference();
        self.resource = null;
        self.shm = null;
        self.dmabuf = null;
        self.single_pixel = null;
    }

    fn hasBuffer(self: *const Attachment) bool {
        return self.shm != null or self.dmabuf != null or self.single_pixel != null;
    }

    fn handleResourceDestroy(
        listener: *wl.Listener(*wl.Resource),
        _: *wl.Resource,
    ) void {
        const self: *Attachment = @fieldParentPtr("destroy_listener", listener);
        listener.link.remove();
        self.resource = null;
    }
};

const BufferGeometry = struct {
    buffer_size: render_types.Size,
    logical_size: render_types.Size,
    transform: wl.Output.Transform,
    source: ?render_types.SourceRect,
};

fn currentBufferGeometry(surface_state: *const State) ?BufferGeometry {
    const buffer = surface_state.current_buffer orelse return null;
    return .{
        .buffer_size = buffer.buffer_size,
        .logical_size = buffer.logical_size,
        .transform = buffer.transform,
        .source = buffer.source,
    };
}

fn updateCurrentDamage(
    surface_state: *State,
    previous_geometry: ?BufferGeometry,
    surface_damage: *const Region,
    buffer_damage: *const Region,
    offset_changed: bool,
) void {
    surface_state.current_damage.clear();
    surface_state.current_damage_precise = !offset_changed;
    const current_geometry = currentBufferGeometry(surface_state);
    if (!std.meta.eql(previous_geometry, current_geometry)) {
        const previous_size = if (previous_geometry) |geometry|
            geometry.logical_size
        else
            render_types.Size{ .width = 0, .height = 0 };
        const current_size = if (current_geometry) |geometry|
            geometry.logical_size
        else
            render_types.Size{ .width = 0, .height = 0 };
        surface_state.current_damage.setRectangle(
            0,
            0,
            @max(previous_size.width, current_size.width),
            @max(previous_size.height, current_size.height),
        );
        return;
    }

    surface_state.current_damage.copyFrom(surface_damage) catch {
        return setFullCurrentDamage(surface_state);
    };
    const buffer = if (surface_state.current_buffer) |*current| current else return;
    if (!addBufferDamage(&surface_state.current_damage, buffer_damage, buffer)) {
        setFullCurrentDamage(surface_state);
    }
}

fn currentCommitIsCallbackOnly(surface_state: *const State) bool {
    return surface_state.current_damage_precise and surface_state.current_damage.isEmpty();
}

fn setFullCurrentDamage(surface_state: *State) void {
    const size = if (surface_state.current_buffer) |buffer|
        buffer.logical_size
    else
        render_types.Size{ .width = 0, .height = 0 };
    surface_state.current_damage.setRectangle(0, 0, size.width, size.height);
}

fn addBufferDamage(
    destination: *Region,
    damage: *const Region,
    buffer: *const BufferSnapshot,
) bool {
    if (buffer.transform != .normal) return damage.isEmpty();
    const source = buffer.source orelse render_types.SourceRect{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(buffer.buffer_size.width),
        .height = @floatFromInt(buffer.buffer_size.height),
    };
    const logical_width: f64 = @floatFromInt(buffer.logical_size.width);
    const logical_height: f64 = @floatFromInt(buffer.logical_size.height);
    var rectangles = damage.rectangleIterator();
    while (rectangles.next()) |rectangle| {
        const rectangle_left: f64 = @floatFromInt(rectangle.x);
        const rectangle_top: f64 = @floatFromInt(rectangle.y);
        const rectangle_right = rectangle_left + @as(f64, @floatFromInt(rectangle.width));
        const rectangle_bottom = rectangle_top + @as(f64, @floatFromInt(rectangle.height));
        const left = @max(rectangle_left, source.x);
        const top = @max(rectangle_top, source.y);
        const right = @min(rectangle_right, source.x + source.width);
        const bottom = @min(rectangle_bottom, source.y + source.height);
        if (right <= left or bottom <= top) continue;

        const logical_left = std.math.clamp(
            @floor((left - source.x) * logical_width / source.width),
            0,
            logical_width,
        );
        const logical_top = std.math.clamp(
            @floor((top - source.y) * logical_height / source.height),
            0,
            logical_height,
        );
        const logical_right = std.math.clamp(
            @ceil((right - source.x) * logical_width / source.width),
            0,
            logical_width,
        );
        const logical_bottom = std.math.clamp(
            @ceil((bottom - source.y) * logical_height / source.height),
            0,
            logical_height,
        );
        const x: i32 = @intFromFloat(logical_left);
        const y: i32 = @intFromFloat(logical_top);
        const width: i32 = @intFromFloat(logical_right - logical_left);
        const height: i32 = @intFromFloat(logical_bottom - logical_top);
        destination.add(x, y, width, height) catch return false;
    }
    return true;
}

const DmabufUse = struct {
    allocator: std.mem.Allocator,
    reference_count: usize,
    buffer: *LinuxDmabuf.Buffer,
    synchronization: ?DrmSyncobj.Commit,
    acquire_ready: bool,
    acquire_waiter: ?*DrmSyncobj.Waiter,
    acquire_store: ?*Store,
    acquire_surface_id: Id = undefined,
    acquire_cached_sequence: u64,
    gpu_accessed: bool,
    release_store: ?*Store = null,
    release_surface_id: Id = undefined,
    release_generation: u64 = 0,

    fn create(
        buffer: *LinuxDmabuf.Buffer,
        synchronization: ?DrmSyncobj.Commit,
    ) error{OutOfMemory}!*DmabufUse {
        const self = buffer.manager.allocator.create(DmabufUse) catch return error.OutOfMemory;
        buffer.retainSnapshot();
        self.* = .{
            .allocator = buffer.manager.allocator,
            .reference_count = 1,
            .buffer = buffer,
            .synchronization = synchronization,
            .acquire_ready = synchronization == null or synchronization.?.acquire.signaled(),
            .acquire_waiter = null,
            .acquire_store = null,
            .acquire_cached_sequence = 0,
            .gpu_accessed = false,
        };
        if (!self.acquire_ready) {
            self.acquire_waiter = synchronization.?.acquire.wait(self, acquireReady) catch {
                buffer.releaseSnapshot();
                self.allocator.destroy(self);
                return error.OutOfMemory;
            };
        }
        return self;
    }

    fn isReady(self: *DmabufUse) bool {
        if (self.acquire_ready) return true;
        if (!self.synchronization.?.acquire.signaled()) return false;
        if (self.acquire_waiter) |waiter| {
            self.acquire_waiter = null;
            waiter.destroy();
        }
        self.acquire_ready = true;
        return true;
    }

    fn setAcquireReadyTarget(
        self: *DmabufUse,
        store: *Store,
        surface_id: Id,
        sequence: u64,
    ) void {
        std.debug.assert(!self.acquire_ready and self.acquire_store == null);
        self.acquire_store = store;
        self.acquire_surface_id = surface_id;
        self.acquire_cached_sequence = sequence;
    }

    fn acquireReady(context: *anyopaque, ready: bool) void {
        const self: *DmabufUse = @ptrCast(@alignCast(context));
        self.acquire_waiter = null;
        if (!ready) {
            log.warn("DRM syncobj acquire waiter failed", .{});
            return;
        }
        self.acquire_ready = true;
        const store = self.acquire_store orelse return;
        const surface_state = store.get(self.acquire_surface_id) orelse return;
        for (surface_state.cached_commits.items) |*cached| {
            if (cached.sequence != self.acquire_cached_sequence) continue;
            cached.sync_ready = true;
            applyReadyCached(Self.fromResource(surface_state.resource));
            return;
        }
    }

    fn setRelease(self: *DmabufUse, store: *Store, surface_id: Id, generation: u64) void {
        std.debug.assert(self.release_store == null);
        self.release_store = store;
        self.release_surface_id = surface_id;
        self.release_generation = generation;
    }

    fn reference(self: *DmabufUse) void {
        std.debug.assert(self.reference_count > 0);
        self.reference_count += 1;
    }

    fn unreference(self: *DmabufUse) void {
        std.debug.assert(self.reference_count > 0);
        self.reference_count -= 1;
        if (self.reference_count != 0) return;
        if (self.acquire_waiter) |waiter| waiter.destroy();
        if (self.synchronization) |*synchronization| {
            const release_succeeded = if (self.gpu_accessed) completed: {
                const source = self.buffer.renderSource();
                const sync_file_fd = source.export_read_fence(source.context, 0) orelse
                    break :completed false;
                defer _ = std.c.close(sync_file_fd);
                break :completed synchronization.release.importSyncFile(sync_file_fd);
            } else synchronization.release.signal();
            if (!release_succeeded) {
                log.warn("failed to signal DRM syncobj release point", .{});
            }
            synchronization.deinit();
        }
        self.buffer.releaseSnapshot();
        if (self.release_store) |store| {
            finishBufferReleaseCallbacks(store, self.release_surface_id, self.release_generation);
        }
        self.allocator.destroy(self);
    }

    fn renderSource(self: *DmabufUse) render_types.DmabufSource {
        var source = self.buffer.renderSource();
        source.context = self;
        source.retain = retainCallback;
        source.release = releaseCallback;
        source.begin_cpu_read = beginCpuReadCallback;
        source.end_cpu_read = endCpuReadCallback;
        source.export_read_fence = exportReadFenceCallback;
        return source;
    }

    fn retainCallback(context: *anyopaque) void {
        const self: *DmabufUse = @ptrCast(@alignCast(context));
        self.reference();
    }

    fn releaseCallback(context: *anyopaque) void {
        const self: *DmabufUse = @ptrCast(@alignCast(context));
        self.unreference();
    }

    fn beginCpuReadCallback(context: *anyopaque) bool {
        const self: *DmabufUse = @ptrCast(@alignCast(context));
        if (!self.isReady()) return false;
        const source = self.buffer.renderSource();
        return source.begin_cpu_read(source.context);
    }

    fn endCpuReadCallback(context: *anyopaque) bool {
        const self: *DmabufUse = @ptrCast(@alignCast(context));
        const source = self.buffer.renderSource();
        return source.end_cpu_read(source.context);
    }

    fn exportReadFenceCallback(context: *anyopaque, plane_index: u8) ?std.posix.fd_t {
        const self: *DmabufUse = @ptrCast(@alignCast(context));
        if (self.synchronization) |synchronization| {
            if (!self.isReady()) return null;
            self.gpu_accessed = true;
            return synchronization.acquire.exportSyncFile();
        }
        const source = self.buffer.renderSource();
        return source.export_read_fence(source.context, plane_index);
    }
};

pub const BufferSnapshot = struct {
    buffer_size: render_types.Size,
    logical_size: render_types.Size,
    scale: i32,
    transform: wl.Output.Transform,
    source: ?render_types.SourceRect,
    force_opaque: bool,
    copied: ?CopiedBufferSnapshot,
    dmabuf: ?*DmabufUse = null,
    color_description: render_types.ColorDescription = .{},
    color_representation: render_types.ColorRepresentation = .{},
    source_cache: render_types.SourceCache,

    const Error = error{
        OutOfMemory,
        InvalidSize,
        InvalidBuffer,
        BadViewportSize,
        ViewportOutOfBuffer,
        ImportFailed,
    };

    fn copyShm(
        allocator: std.mem.Allocator,
        shm_buffer: *wl.shm.Buffer,
        scale: i32,
        transform: wl.Output.Transform,
        viewport: ViewportState,
        allow_non_divisible_scale: bool,
        reusable: ?*BufferSnapshot,
        surface_damage: *const Region,
        buffer_damage: *const Region,
        source_cache: render_types.SourceCache,
    ) Error!BufferSnapshot {
        const width = shm_buffer.getWidth();
        const height = shm_buffer.getHeight();
        const stride = shm_buffer.getStride();
        if (width <= 0 or height <= 0 or stride <= 0) return error.InvalidBuffer;

        const buffer_size: render_types.Size = .{
            .width = @intCast(width),
            .height = @intCast(height),
        };
        const geometry = surface_geometry.calculate(
            buffer_size,
            scale,
            transform,
            viewport,
            allow_non_divisible_scale,
        ) catch |err| return err;
        const format = shm_buffer.getFormat();
        const argb8888: u32 = @intCast(@intFromEnum(wl.Shm.Format.argb8888));
        const xrgb8888: u32 = @intCast(@intFromEnum(wl.Shm.Format.xrgb8888));
        if (format != argb8888 and format != xrgb8888) return error.InvalidBuffer;

        shm_buffer.beginAccess();
        defer shm_buffer.endAccess();
        const data = shm_buffer.getData() orelse return error.InvalidBuffer;
        const can_update_partially = if (reusable) |snapshot|
            snapshot.copied != null and
                std.meta.eql(snapshot.buffer_size, buffer_size) and
                std.meta.eql(snapshot.logical_size, geometry.logical_size) and
                snapshot.transform == transform and
                std.meta.eql(snapshot.source, geometry.source) and
                surface_damage.isEmpty()
        else
            false;
        const source_stride: usize = @intCast(stride);
        const row_bytes = std.math.mul(usize, buffer_size.width, @sizeOf(u32)) catch
            return error.InvalidBuffer;
        const preceding_rows = std.math.mul(usize, buffer_size.height - 1, source_stride) catch
            return error.InvalidBuffer;
        const source_len = std.math.add(usize, preceding_rows, row_bytes) catch
            return error.InvalidBuffer;
        const source_bytes: [*]const u8 = @ptrCast(data);
        const reusable_copy = if (reusable) |snapshot|
            if (snapshot.copied) |*copied| copied else null
        else
            null;
        const copied = CopiedBufferSnapshot.copy(
            allocator,
            .{
                .bytes = source_bytes[0..source_len],
                .size = buffer_size,
                .stride_bytes = source_stride,
                .format = if (format == xrgb8888) .xrgb8888 else .argb8888,
            },
            reusable_copy,
            if (can_update_partially) buffer_damage else null,
            source_cache,
        ) catch |err| return err;

        return .{
            .buffer_size = buffer_size,
            .logical_size = geometry.logical_size,
            .scale = scale,
            .transform = transform,
            .source = geometry.source,
            .force_opaque = copied.forceOpaque(),
            .copied = copied,
            .dmabuf = null,
            .source_cache = source_cache,
        };
    }

    fn retainDmabuf(
        buffer: *LinuxDmabuf.Buffer,
        scale: i32,
        transform: wl.Output.Transform,
        viewport: ViewportState,
        allow_non_divisible_scale: bool,
        synchronization: ?DrmSyncobj.Commit,
    ) Error!BufferSnapshot {
        var owned_synchronization = synchronization;
        errdefer if (owned_synchronization) |*sync| sync.deinit();
        const buffer_size = buffer.size();
        const geometry = try surface_geometry.calculate(
            buffer_size,
            scale,
            transform,
            viewport,
            allow_non_divisible_scale,
        );
        const dmabuf = try DmabufUse.create(buffer, owned_synchronization);
        owned_synchronization = null;
        const source_cache = buffer.acquireSourceCache();

        return .{
            .buffer_size = buffer_size,
            .logical_size = geometry.logical_size,
            .scale = scale,
            .transform = transform,
            .source = geometry.source,
            .force_opaque = buffer.renderSource().force_opaque,
            .copied = null,
            .dmabuf = dmabuf,
            .source_cache = source_cache,
        };
    }

    fn copySinglePixel(
        allocator: std.mem.Allocator,
        pixel: u32,
        scale: i32,
        transform: wl.Output.Transform,
        viewport: ViewportState,
        allow_non_divisible_scale: bool,
        reusable: ?*BufferSnapshot,
        source_cache: render_types.SourceCache,
    ) Error!BufferSnapshot {
        const buffer_size: render_types.Size = .{ .width = 1, .height = 1 };
        const geometry = try surface_geometry.calculate(
            buffer_size,
            scale,
            transform,
            viewport,
            allow_non_divisible_scale,
        );
        const reusable_copy = if (reusable) |snapshot|
            if (snapshot.copied) |*copied| copied else null
        else
            null;
        const bytes = std.mem.asBytes(&pixel);
        const copied = CopiedBufferSnapshot.copy(allocator, .{
            .bytes = bytes,
            .size = buffer_size,
            .stride_bytes = @sizeOf(u32),
            .format = .argb8888,
        }, reusable_copy, null, source_cache) catch |err| return err;
        return .{
            .buffer_size = buffer_size,
            .logical_size = geometry.logical_size,
            .scale = scale,
            .transform = transform,
            .source = geometry.source,
            .force_opaque = pixel >> 24 == 0xff,
            .copied = copied,
            .dmabuf = null,
            .source_cache = source_cache,
        };
    }

    fn updateGeometry(
        self: *BufferSnapshot,
        scale: i32,
        transform: wl.Output.Transform,
        viewport: ViewportState,
        allow_non_divisible_scale: bool,
    ) Error!void {
        const geometry = try surface_geometry.calculate(
            self.buffer_size,
            scale,
            transform,
            viewport,
            allow_non_divisible_scale,
        );
        self.logical_size = geometry.logical_size;
        self.scale = scale;
        self.transform = transform;
        self.source = geometry.source;
    }

    pub fn deinit(self: *BufferSnapshot) void {
        if (self.copied) |*copied| copied.deinit();
        if (self.dmabuf) |dmabuf| dmabuf.unreference();
        self.* = undefined;
    }

    fn retainsClientBuffer(self: *const BufferSnapshot) bool {
        return self.dmabuf != null;
    }

    fn isReady(self: *BufferSnapshot) bool {
        return if (self.dmabuf) |dmabuf| dmabuf.isReady() else true;
    }

    fn bufferFormat(self: *const BufferSnapshot) render_types.DmabufFormat {
        return if (self.dmabuf) |dmabuf|
            render_types.DmabufFormat.fromFourcc(dmabuf.buffer.format()).?
        else
            .argb8888;
    }

    pub fn pixelBuffer(self: *BufferSnapshot) render_types.PixelBuffer {
        if (self.copied) |*copied| return copied.pixelBuffer(
            self.color_description,
            self.color_representation,
        );
        const dmabuf_source = if (self.dmabuf) |dmabuf| dmabuf.renderSource() else null;
        return .{
            .size = self.buffer_size,
            .stride_pixels = if (dmabuf_source) |dmabuf|
                if (render_types.DmabufFormat.fromFourcc(dmabuf.format).?.isPackedRgb())
                    dmabuf.planes[0].stride / @sizeOf(u32)
                else
                    self.buffer_size.width
            else
                self.buffer_size.width,
            .pixels = &.{},
            .dmabuf = dmabuf_source,
            .color_description = self.color_description,
            .color_representation = self.color_representation,
            .source_cache = self.source_cache,
        };
    }
};

const FrameCallback = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    surface_id: Id,
    resource: *wl.Callback,
    state: enum { pending, cached, active, submitted },
    cached_sequence: ?u64,
    callback_only: bool,

    fn handleDestroy(resource: *wl.Resource) callconv(.c) void {
        const self: *FrameCallback = @ptrCast(@alignCast(resource.getUserData().?));
        removeCallback(self.store, self.surface_id, self);
        self.allocator.destroy(self);
    }
};

const BufferReleaseCallback = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    surface_id: Id,
    resource: *wl.Callback,
    generation: ?u64,

    fn handleDestroy(resource: *wl.Resource) callconv(.c) void {
        const self: *BufferReleaseCallback = @ptrCast(@alignCast(resource.getUserData().?));
        removeBufferReleaseCallback(self.store, self.surface_id, self);
        self.allocator.destroy(self);
    }
};

fn createFrameCallback(self: *Self, id: u32) error{OutOfMemory}!void {
    const resource = wl.Callback.create(self.resource.getClient(), 1, id) catch
        return error.OutOfMemory;
    errdefer resource.destroy();

    const callback = self.allocator.create(FrameCallback) catch return error.OutOfMemory;
    errdefer self.allocator.destroy(callback);
    callback.* = .{
        .allocator = self.allocator,
        .store = self.store,
        .surface_id = self.id,
        .resource = resource,
        .state = .pending,
        .cached_sequence = null,
        .callback_only = false,
    };
    try self.state().callbacks.append(self.allocator, callback);

    @as(*wl.Resource, @ptrCast(resource)).setDispatcher(
        null,
        null,
        callback,
        FrameCallback.handleDestroy,
    );
}

fn createBufferReleaseCallback(self: *Self, id: u32) error{OutOfMemory}!void {
    const resource = wl.Callback.create(self.resource.getClient(), 1, id) catch
        return error.OutOfMemory;
    errdefer resource.destroy();

    const callback = self.allocator.create(BufferReleaseCallback) catch
        return error.OutOfMemory;
    errdefer self.allocator.destroy(callback);
    callback.* = .{
        .allocator = self.allocator,
        .store = self.store,
        .surface_id = self.id,
        .resource = resource,
        .generation = null,
    };
    try self.state().release_callbacks.append(self.allocator, callback);

    @as(*wl.Resource, @ptrCast(resource)).setDispatcher(
        null,
        null,
        callback,
        BufferReleaseCallback.handleDestroy,
    );
}

fn removeCallback(store: *Store, surface_id: Id, callback: *FrameCallback) void {
    const surface_state = store.get(surface_id) orelse unreachable;
    for (surface_state.callbacks.items, 0..) |candidate, index| {
        if (candidate == callback) {
            _ = surface_state.callbacks.orderedRemove(index);
            return;
        }
    }
    unreachable;
}

fn removeBufferReleaseCallback(
    store: *Store,
    surface_id: Id,
    callback: *BufferReleaseCallback,
) void {
    const surface_state = store.get(surface_id) orelse unreachable;
    for (surface_state.release_callbacks.items, 0..) |candidate, index| {
        if (candidate == callback) {
            _ = surface_state.release_callbacks.orderedRemove(index);
            return;
        }
    }
    unreachable;
}

extern fn wl_shm_buffer_ref(buffer: *wl.shm.Buffer) *wl.shm.Buffer;
extern fn wl_shm_buffer_unref(buffer: *wl.shm.Buffer) void;

test "single pixel snapshots use viewporter destination without changing color" {
    var snapshot = try BufferSnapshot.copySinglePixel(
        std.testing.allocator,
        0x8040_2000,
        1,
        .normal,
        .{ .destination = .{ .width = 320, .height = 180 } },
        false,
        null,
        .{ .id = 1, .version = 1 },
    );
    defer snapshot.deinit();

    try std.testing.expectEqual(
        render_types.Size{ .width = 1, .height = 1 },
        snapshot.buffer_size,
    );
    try std.testing.expectEqual(
        render_types.Size{ .width = 320, .height = 180 },
        snapshot.logical_size,
    );
    try std.testing.expectEqualSlices(u32, &.{0x8040_2000}, snapshot.copied.?.pixels);
}

test "same-size snapshots recycle pixel storage" {
    var first = try BufferSnapshot.copySinglePixel(
        std.testing.allocator,
        0x1122_3344,
        1,
        .normal,
        .{},
        false,
        null,
        .{ .id = 1, .version = 1 },
    );
    defer first.deinit();
    const original_pointer = first.copied.?.pixels.ptr;

    var second = try BufferSnapshot.copySinglePixel(
        std.testing.allocator,
        0x5566_7788,
        1,
        .normal,
        .{},
        false,
        &first,
        .{ .id = 1, .version = 2 },
    );
    defer second.deinit();

    try std.testing.expectEqual(@as(usize, 0), first.copied.?.pixels.len);
    try std.testing.expectEqual(original_pointer, second.copied.?.pixels.ptr);
    try std.testing.expectEqualSlices(u32, &.{0x5566_7788}, second.copied.?.pixels);
}

test "buffer damage maps into logical surface coordinates" {
    const buffer: BufferSnapshot = .{
        .buffer_size = .{ .width = 200, .height = 100 },
        .logical_size = .{ .width = 100, .height = 50 },
        .scale = 2,
        .transform = .normal,
        .source = null,
        .force_opaque = false,
        .copied = null,
        .source_cache = .{ .id = 1, .version = 1 },
    };
    var buffer_damage = Region.init();
    defer buffer_damage.deinit();
    try buffer_damage.add(20, 10, 40, 20);
    var surface_damage = Region.init();
    defer surface_damage.deinit();

    try std.testing.expect(addBufferDamage(&surface_damage, &buffer_damage, &buffer));
    var rectangles = surface_damage.rectangleIterator();
    try std.testing.expectEqual(
        Region.Rectangle{ .x = 10, .y = 5, .width = 20, .height = 10 },
        rectangles.next().?,
    );
    try std.testing.expectEqual(@as(?Region.Rectangle, null), rectangles.next());
}

test "callback-only commits require precise empty damage" {
    var surface_state = State.init(undefined);
    defer surface_state.deinit(std.testing.allocator);

    surface_state.current_damage_precise = true;
    try std.testing.expect(currentCommitIsCallbackOnly(&surface_state));

    try surface_state.current_damage.add(0, 0, 1, 1);
    try std.testing.expect(!currentCommitIsCallbackOnly(&surface_state));

    surface_state.current_damage.clear();
    surface_state.current_damage_precise = false;
    try std.testing.expect(!currentCommitIsCallbackOnly(&surface_state));
}

test "detached buffers remain in surface commit history" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const id = try store.insert(std.testing.allocator, State.init(undefined));
    var surface: Self = .{
        .allocator = std.testing.allocator,
        .store = &store,
        .id = id,
        .resource = undefined,
        .pending_attachment = .{},
        .has_pending_attachment = false,
        .role_handler = null,
        .viewport_handler = null,
        .content_type_handler = null,
        .color_representation_handler = null,
        .alpha_modifier_handler = null,
        .tearing_control_handler = null,
        .fifo_handler = null,
        .commit_timer_handler = null,
        .background_effect_handler = null,
        .explicit_sync_handler = null,
        .commit_listeners = .empty,
        .notifying_commit_listeners = false,
    };
    defer surface.commit_listeners.deinit(std.testing.allocator);
    defer {
        var removed = store.remove(id).?;
        removed.deinit(std.testing.allocator);
    }

    surface.state().has_committed_buffer = true;
    try std.testing.expect(!surface.hasBufferAttached());
    try std.testing.expect(surface.hasBufferAttachedOrCommitted());
}

test "FIFO waits block only while a relevant barrier is active" {
    try std.testing.expect(fifoCommitReady(false, false, true));
    try std.testing.expect(fifoCommitReady(true, false, false));
    try std.testing.expect(!fifoCommitReady(true, false, true));
    try std.testing.expect(fifoCommitReady(true, true, true));
}

test "FIFO barriers attach to one visible output until replaced" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const id = try store.insert(std.testing.allocator, State.init(undefined));
    defer {
        var removed = store.remove(id).?;
        removed.deinit(std.testing.allocator);
    }
    const surface_state = store.get(id).?;
    applyFifoSet(surface_state, true);

    var first_output: u8 = 0;
    var second_output: u8 = 0;
    markFifoBarrierVisible(&store, id, &first_output);
    markFifoBarrierVisible(&store, id, &second_output);
    try std.testing.expect(hasFifoBarrierForOutput(&store, &first_output));
    try std.testing.expect(!hasFifoBarrierForOutput(&store, &second_output));

    applyFifoSet(surface_state, true);
    try std.testing.expect(!hasFifoBarrierForOutput(&store, &first_output));
    try std.testing.expect(surface_state.fifo_barrier_output == null);
}

fn testCachedCommit(
    sequence: u64,
    role_ready: bool,
    target_timestamp: ?i96,
    timing_ready: bool,
) CachedCommit {
    return .{
        .sequence = sequence,
        .role_ready = role_ready,
        .sync_ready = true,
        .fifo_set = false,
        .fifo_wait = false,
        .fifo_wait_ignored = false,
        .target_timestamp = target_timestamp,
        .timing_ready = timing_ready,
        .buffer = null,
        .attachment_changed = false,
        .has_buffer = false,
        .offset_x = 0,
        .offset_y = 0,
        .scale = 1,
        .transform = .normal,
        .viewport = .{},
        .content_type = .none,
        .color_description = .{},
        .alpha_multiplier = std.math.maxInt(u32),
        .color_representation = .{},
        .presentation_hint = .vsync,
        .blur_region = Region.init(),
        .blur_region_changed = false,
        .surface_damage = Region.init(),
        .buffer_damage = Region.init(),
        .opaque_region = Region.init(),
        .input = InputRegion.init(),
    };
}

test "commit timing finds the earliest pending or cached target" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const id = try store.insert(std.testing.allocator, State.init(undefined));
    defer {
        var removed = store.remove(id).?;
        removed.deinit(std.testing.allocator);
    }

    const surface_state = store.get(id).?;
    surface_state.pending_commit_timestamp = 50;
    surface_state.pending_timing_ready = false;
    try surface_state.cached_commits.append(
        std.testing.allocator,
        testCachedCommit(1, true, 20, true),
    );
    try surface_state.cached_commits.append(
        std.testing.allocator,
        testCachedCommit(2, true, 30, false),
    );

    try std.testing.expectEqual(@as(?i96, 30), earliestCommitTimestamp(&store));
    surface_state.cached_commits.items[1].timing_ready = true;
    try std.testing.expectEqual(@as(?i96, 50), earliestCommitTimestamp(&store));
    surface_state.pending_timing_ready = true;
    try std.testing.expectEqual(@as(?i96, null), earliestCommitTimestamp(&store));
}

test "commit timing preserves synchronized and ordered application" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const id = try store.insert(std.testing.allocator, State.init(undefined));
    var surface: Self = .{
        .allocator = std.testing.allocator,
        .store = &store,
        .id = id,
        .resource = undefined,
        .pending_attachment = .{},
        .has_pending_attachment = false,
        .role_handler = null,
        .viewport_handler = null,
        .content_type_handler = null,
        .color_representation_handler = null,
        .alpha_modifier_handler = null,
        .tearing_control_handler = null,
        .fifo_handler = null,
        .commit_timer_handler = null,
        .background_effect_handler = null,
        .explicit_sync_handler = null,
        .commit_listeners = .empty,
        .notifying_commit_listeners = false,
    };
    defer surface.commit_listeners.deinit(std.testing.allocator);
    defer {
        var removed = store.remove(id).?;
        removed.deinit(std.testing.allocator);
    }

    const surface_state = store.get(id).?;
    try surface_state.cached_commits.append(
        std.testing.allocator,
        testCachedCommit(1, false, 20, false),
    );
    try surface_state.cached_commits.append(
        std.testing.allocator,
        testCachedCommit(2, false, null, true),
    );

    surface.applyCachedUpTo(std.math.maxInt(u64));
    try std.testing.expectEqual(@as(usize, 2), surface_state.cached_commits.items.len);
    try std.testing.expect(!releaseTimedCommitState(surface_state, 19));
    try std.testing.expectEqual(@as(usize, 2), surface_state.cached_commits.items.len);
    try std.testing.expect(releaseTimedCommitState(surface_state, 20));
    applyReadyCached(&surface);
    try std.testing.expectEqual(@as(usize, 0), surface_state.cached_commits.items.len);
}

test "commit timing moves a pending target to exactly one cached commit" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const id = try store.insert(std.testing.allocator, State.init(undefined));
    var surface: Self = .{
        .allocator = std.testing.allocator,
        .store = &store,
        .id = id,
        .resource = undefined,
        .pending_attachment = .{},
        .has_pending_attachment = false,
        .role_handler = null,
        .viewport_handler = null,
        .content_type_handler = null,
        .color_representation_handler = null,
        .alpha_modifier_handler = null,
        .tearing_control_handler = null,
        .fifo_handler = null,
        .commit_timer_handler = null,
        .background_effect_handler = null,
        .explicit_sync_handler = null,
        .commit_listeners = .empty,
        .notifying_commit_listeners = false,
    };
    defer surface.commit_listeners.deinit(std.testing.allocator);
    defer {
        var removed = store.remove(id).?;
        removed.deinit(std.testing.allocator);
    }

    const surface_state = store.get(id).?;
    surface_state.pending_commit_timestamp = 42;
    surface_state.pending_timing_ready = false;
    try std.testing.expect(cachePending(&surface, false));
    try std.testing.expectEqual(@as(?i96, null), surface_state.pending_commit_timestamp);
    try std.testing.expect(surface_state.pending_timing_ready);
    try std.testing.expectEqual(@as(usize, 1), surface_state.cached_commits.items.len);
    try std.testing.expectEqual(
        @as(?i96, 42),
        surface_state.cached_commits.items[0].target_timestamp,
    );
    try std.testing.expect(!surface_state.cached_commits.items[0].timing_ready);
}

test "synchronized application ignores FIFO waits while desynchronized application blocks" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const id = try store.insert(std.testing.allocator, State.init(undefined));
    var surface: Self = .{
        .allocator = std.testing.allocator,
        .store = &store,
        .id = id,
        .resource = undefined,
        .pending_attachment = .{},
        .has_pending_attachment = false,
        .role_handler = null,
        .viewport_handler = null,
        .content_type_handler = null,
        .color_representation_handler = null,
        .alpha_modifier_handler = null,
        .tearing_control_handler = null,
        .fifo_handler = null,
        .commit_timer_handler = null,
        .background_effect_handler = null,
        .explicit_sync_handler = null,
        .commit_listeners = .empty,
        .notifying_commit_listeners = false,
    };
    defer surface.commit_listeners.deinit(std.testing.allocator);
    defer {
        var removed = store.remove(id).?;
        removed.deinit(std.testing.allocator);
    }

    const surface_state = store.get(id).?;
    surface_state.fifo_barrier = true;
    try surface_state.cached_commits.append(std.testing.allocator, .{
        .sequence = 1,
        .role_ready = false,
        .sync_ready = true,
        .fifo_set = false,
        .fifo_wait = true,
        .fifo_wait_ignored = false,
        .target_timestamp = null,
        .timing_ready = true,
        .buffer = null,
        .attachment_changed = false,
        .has_buffer = false,
        .offset_x = 0,
        .offset_y = 0,
        .scale = 1,
        .transform = .normal,
        .viewport = .{},
        .content_type = .none,
        .color_description = .{},
        .color_representation = .{},
        .alpha_multiplier = std.math.maxInt(u32),
        .presentation_hint = .vsync,
        .blur_region = Region.init(),
        .blur_region_changed = false,
        .surface_damage = Region.init(),
        .buffer_damage = Region.init(),
        .opaque_region = Region.init(),
        .input = InputRegion.init(),
    });

    surface.applyCachedCommit();
    try std.testing.expectEqual(@as(usize, 1), surface_state.cached_commits.items.len);
    surface.applyCachedUpTo(std.math.maxInt(u64));
    try std.testing.expectEqual(@as(usize, 0), surface_state.cached_commits.items.len);
}
