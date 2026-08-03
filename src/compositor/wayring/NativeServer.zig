//! Stable-address owner for the native, headless Wayring compositor slice.
//!
//! Protocol dispatch enqueues transactions. The EventLoop prepares each
//! root's FIFO independently, then atomically applies ready transactions.

const NativeServer = @This();

const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const generated = @import("wayring-protocols");
const keywork_loop = @import("keywork-loop");
const Server = @import("wayring-server");
const IoUringServer = @import("wayring-server-uring");
const SecurityContextGlobal = @import("SecurityContextGlobal.zig");
const FixesGlobal = @import("FixesGlobal.zig");
const ShmGlobal = @import("ShmGlobal.zig");
const SinglePixelBufferGlobal = @import("SinglePixelBufferGlobal.zig");
const LinuxDmabufGlobal = @import("LinuxDmabufGlobal.zig");
const LinuxDrmSyncobjGlobal = @import("LinuxDrmSyncobjGlobal.zig");
const BufferResource = @import("BufferResource.zig");
const CompositorGlobal = @import("CompositorGlobal.zig");
const OutputGlobal = @import("OutputGlobal.zig");
const XdgOutputGlobal = @import("XdgOutputGlobal.zig");
const ScreencopyGlobal = @import("ScreencopyGlobal.zig");
const PresentationGlobal = @import("PresentationGlobal.zig");
const ContentTypeGlobal = @import("ContentTypeGlobal.zig");
const ColorRepresentationGlobal = @import("ColorRepresentationGlobal.zig");
const AlphaModifierGlobal = @import("AlphaModifierGlobal.zig");
const BackgroundEffectGlobal = @import("BackgroundEffectGlobal.zig");
const TearingControlGlobal = @import("TearingControlGlobal.zig");
const FifoGlobal = @import("FifoGlobal.zig");
const CommitTimingGlobal = @import("CommitTimingGlobal.zig");
const SeatGlobal = @import("SeatGlobal.zig");
const TransientSeatGlobal = @import("TransientSeatGlobal.zig");
const VirtualKeyboardGlobal = @import("VirtualKeyboardGlobal.zig");
const VirtualPointerGlobal = @import("VirtualPointerGlobal.zig");
const XdgActivationGlobal = @import("XdgActivationGlobal.zig");
const IdleNotifyGlobal = @import("IdleNotifyGlobal.zig");
const IdleInhibitGlobal = @import("IdleInhibitGlobal.zig");
const PointerCursor = @import("PointerCursor.zig");
const KeyboardShortcutsInhibitGlobal = @import("KeyboardShortcutsInhibitGlobal.zig");
const RelativePointerGlobal = @import("RelativePointerGlobal.zig");
const PointerWarpGlobal = @import("PointerWarpGlobal.zig");
const PointerGesturesGlobal = @import("PointerGesturesGlobal.zig");
const TabletGlobal = @import("TabletGlobal.zig");
const CursorShapeGlobal = @import("CursorShapeGlobal.zig");
const DataDeviceGlobal = @import("DataDeviceGlobal.zig");
const PrimarySelectionGlobal = @import("PrimarySelectionGlobal.zig");
const DataControlGlobal = @import("DataControlGlobal.zig");
const FractionalScaleGlobal = @import("FractionalScaleGlobal.zig");
const ViewporterGlobal = @import("ViewporterGlobal.zig");
const XdgDecorationGlobal = @import("XdgDecorationGlobal.zig");
const XdgDialogGlobal = @import("XdgDialogGlobal.zig");
const GtkShellGlobal = @import("GtkShellGlobal.zig");
const XdgShell = @import("XdgShell.zig");
const LayerShell = @import("LayerShell.zig");
const ForeignToplevelListGlobal = @import("ForeignToplevelListGlobal.zig");
const XdgSystemBellGlobal = @import("XdgSystemBellGlobal.zig");
const XdgToplevelIconGlobal = @import("XdgToplevelIconGlobal.zig");
const XdgToplevelTagGlobal = @import("XdgToplevelTagGlobal.zig");
const SurfaceTree = @import("SurfaceTree.zig");
const SubcompositorGlobal = @import("SubcompositorGlobal.zig");
const AsyncShmCopy = @import("AsyncShmCopy.zig");
const shm = @import("shm.zig");
const DrmSyncobj = @import("../drm_syncobj.zig");
const Renderer = @import("../render/Renderer.zig");
const HeadlessOutput = @import("../backend/headless.zig");
const DrmOutput = @import("../backend/drm.zig");
const DrmDevice = @import("../backend/drm_device.zig");
const NativeInput = @import("../backend/native_input.zig");
const Session = @import("../backend/session.zig");
const Region = @import("../region.zig");
const presentation = @import("../presentation.zig");
const render = @import("../render/types.zig");
const surface_geometry = @import("../surface_geometry.zig");

const EventLoop = keywork_loop.EventLoop;
const IoUringLoop = keywork_loop.IoUringLoop;
const maximum_output_busy_retries = 60;

allocator: std.mem.Allocator,
io: std.Io,
event_loop: EventLoop,
repaint_timer: *EventLoop.Timer,
idle_notify_timer: *EventLoop.Timer,
commit_timing_timer: *EventLoop.Timer,
commit_timing_clock: std.Io.Clock,
commit_timing_armed_target: ?i96 = null,
server: Server,
security_context_global: SecurityContextGlobal,
fixes_global: FixesGlobal,
shm_global: ShmGlobal,
single_pixel_buffer_global: SinglePixelBufferGlobal,
linux_dmabuf_global: LinuxDmabufGlobal,
linux_drm_syncobj_global: LinuxDrmSyncobjGlobal,
compositor_global: CompositorGlobal,
surface_tree: SurfaceTree,
subcompositor_global: SubcompositorGlobal,
output_global: OutputGlobal,
xdg_output_global: XdgOutputGlobal,
screencopy_global: ScreencopyGlobal,
presentation_global: PresentationGlobal,
content_type_global: ContentTypeGlobal,
color_representation_global: ColorRepresentationGlobal,
alpha_modifier_global: AlphaModifierGlobal,
background_effect_global: BackgroundEffectGlobal,
tearing_control_global: TearingControlGlobal,
fifo_global: FifoGlobal,
commit_timing_global: CommitTimingGlobal,
seat_global: SeatGlobal,
transient_seat_global: TransientSeatGlobal,
virtual_keyboard_global: VirtualKeyboardGlobal,
virtual_pointer_global: VirtualPointerGlobal,
xdg_activation_global: XdgActivationGlobal,
idle_notify_global: IdleNotifyGlobal,
idle_inhibit_global: IdleInhibitGlobal,
pointer_cursor: PointerCursor,
keyboard_shortcuts_inhibit_global: KeyboardShortcutsInhibitGlobal,
relative_pointer_global: RelativePointerGlobal,
pointer_warp_global: PointerWarpGlobal,
pointer_gestures_global: PointerGesturesGlobal,
tablet_global: TabletGlobal,
cursor_shape_global: CursorShapeGlobal,
data_device_global: DataDeviceGlobal,
primary_selection_global: PrimarySelectionGlobal,
data_control_global: DataControlGlobal,
fractional_scale_global: FractionalScaleGlobal,
viewporter_global: ViewporterGlobal,
xdg_decoration_global: XdgDecorationGlobal,
xdg_dialog_global: XdgDialogGlobal,
gtk_shell_global: GtkShellGlobal,
xdg_shell: XdgShell,
layer_shell: LayerShell,
foreign_toplevel_list_global: ForeignToplevelListGlobal,
xdg_system_bell_global: XdgSystemBellGlobal,
xdg_toplevel_icon_global: XdgToplevelIconGlobal,
xdg_toplevel_tag_global: XdgToplevelTagGlobal,
transport: IoUringServer,
renderer: Renderer,
output: Output,
session: Session,
session_initialized: bool,
drm_device: DrmDevice,
drm_device_initialized: bool,
drm_listener_installed: bool,
native_input: NativeInput,
native_input_initialized: bool,
native_input_device_listener_installed: bool,
display_name: []u8,
socket_path: [:0]u8,
surfaces: std.ArrayList(*SurfaceState) = .empty,
pending: std.ArrayList(*PendingTransaction) = .empty,
frame_callbacks: std.ArrayList(CompositorGlobal.FrameCallbacks) = .empty,
presentation_pending: std.ArrayList(CompositorGlobal.PresentationFeedbacks) = .empty,
presentation_submitted: std.ArrayList(CompositorGlobal.PresentationFeedbacks) = .empty,
next_surface_sample_tag: u64 = 1,
input_paint_entries: std.ArrayList(SurfaceTree.PaintEntry) = .empty,
routed_keys: std.ArrayList(RoutedKey) = .empty,
routed_buttons: std.ArrayList(RoutedButton) = .empty,
unattributed_keys: std.ArrayList(u32) = .empty,
keyboard_enter_keys: std.ArrayList(u32) = .empty,
touch_routes: std.ArrayList(TouchRoute) = .empty,
pointer_axes: [2]PendingAxis = .{ .{}, .{} },
pointer_axis_source: ?u32 = null,
active_gesture: ?RoutedGesture = null,
keyboard_available: bool = false,
pointer_available: bool = false,
touch_available: bool = false,
pointer_physical_x: f64 = 0,
pointer_physical_y: f64 = 0,
keyboard_modifiers: NativeInput.Modifiers = .{},
last_keyboard_serial: u32 = 0,
exclusive_focus_active: bool = false,
exclusive_focus_restore: ?*CompositorGlobal.Surface = null,
next_touch_id: u32 = 1,
frame_count: u64 = 0,
repaint_needed: bool = false,
fifo_progress_needed: bool = false,
output_busy_retries: u8 = 0,
terminating: bool = false,
signal_fd: i32 = -1,
signal_info: linux.signalfd_siginfo = undefined,
signal_handle: ?IoUringLoop.Handle = null,
signal_mask: std.posix.sigset_t = undefined,
previous_signal_mask: std.posix.sigset_t = undefined,
signals_installed: bool = false,

pub const Options = struct {
    /// Used for relative display names. Defaults to XDG_RUNTIME_DIR.
    runtime_directory: ?[]const u8 = null,
    /// A relative Wayland display name, or an absolute socket path.
    display_name: ?[]const u8 = null,
    output_size: render.Size = .{ .width = 1280, .height = 720 },
    scale: render.Scale = .{},
    refresh_millihertz: i32 = 60_000,
    renderer_kind: Renderer.Kind = .cpu,
    output_kind: OutputKind = .headless,
    drm_device_path: ?[]const u8 = null,
    listen_backlog: u31 = 128,
};

pub const OutputKind = enum { headless, drm };

pub const FrameInspection = struct {
    size: render.Size,
    pixels: []const u32,
    frame_count: u64,
};

const SurfaceState = struct {
    surface: *CompositorGlobal.Surface,
    sample_tag: u64,
    snapshot: ?shm.Snapshot = null,
    dmabuf: ?DmabufState = null,
    scale: i32 = 1,
    transform: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    full_damage: bool = false,
    viewport: surface_geometry.ViewportState = .{},
    opaque_region: Region,
    input_region: CompositorGlobal.InputRegion,
    content_type: CompositorGlobal.ContentType = .none,
    color_representation: CompositorGlobal.ColorRepresentationState = .{},
    alpha_multiplier: u32 = std.math.maxInt(u32),
    // Native XdgShell cannot yet represent fullscreen, so output submission
    // remains vsync-only while retaining this future policy input.
    presentation_hint: CompositorGlobal.PresentationHint = .vsync,
    fifo_barrier: bool = false,

    fn deinit(self: *SurfaceState, allocator: std.mem.Allocator) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        if (self.dmabuf) |*dmabuf| dmabuf.deinit(self.surface.client, true);
        self.opaque_region.deinit();
        self.input_region.deinit();
        self.surface.unreference();
        allocator.destroy(self);
    }
};

const Output = union(OutputKind) {
    headless: HeadlessOutput,
    drm: ?*DrmOutput,

    fn modeSize(self: *const Output) render.Size {
        return switch (self.*) {
            .headless => |output| output.size,
            .drm => |output| output.?.size,
        };
    }

    fn logicalSize(self: *const Output) render.Size {
        return switch (self.*) {
            .headless => |output| output.logicalSize(),
            .drm => |output| output.?.logicalSize(),
        };
    }

    fn physicalSize(self: *const Output) render.Size {
        return switch (self.*) {
            .headless => |output| output.size,
            .drm => |output| output.?.physical_size,
        };
    }

    fn scale(self: *const Output) render.Scale {
        return switch (self.*) {
            .headless => |output| output.scale,
            .drm => |output| output.?.scale,
        };
    }

    fn colorDescription(self: *const Output) render.ColorDescription {
        return switch (self.*) {
            .headless => .{},
            .drm => |output| output.?.colorDescription(),
        };
    }

    fn refreshMillihertz(self: *const Output) i32 {
        return switch (self.*) {
            .headless => |output| output.refreshMillihertz(),
            .drm => |output| output.?.refreshMillihertz(),
        };
    }

    fn presentationClockId(self: *const Output) u32 {
        return switch (self.*) {
            .headless => presentation.monotonic_clock_id,
            .drm => |output| output.?.presentation_clock_id,
        };
    }

    fn name(self: *const Output) []const u8 {
        return switch (self.*) {
            .headless => "HEADLESS-1",
            .drm => |output| output.?.name(),
        };
    }

    fn description(self: *const Output) []const u8 {
        return switch (self.*) {
            .headless => "Keywork headless output",
            .drm => |output| output.?.description(),
        };
    }

    fn make(self: *const Output) []const u8 {
        return switch (self.*) {
            .headless => "keywork",
            .drm => |output| output.?.make() orelse "unknown",
        };
    }

    fn model(self: *const Output) []const u8 {
        return switch (self.*) {
            .headless => "headless",
            .drm => |output| output.?.model() orelse "unknown",
        };
    }
};

const DmabufState = struct {
    buffer: *BufferResource,
    resource: wayring.ObjectHandle,
    source_cache: render.SourceCache,
    synchronization: ?DrmSyncobj.Commit,

    fn deinit(self: *DmabufState, client: *Server.Client, send_release: bool) void {
        if (self.synchronization) |*synchronization| {
            _ = synchronization.release.signal();
            synchronization.deinit();
        }
        if (send_release and self.buffer.isLastUse()) ShmGlobal.releaseBuffer(client, self.resource) catch |err| switch (err) {
            error.UnknownResource, error.StaleObject => {},
            else => {},
        };
        self.buffer.unreference();
        self.* = undefined;
    }
};

const PendingTransaction = struct {
    transaction: CompositorGlobal.Transaction,
    entries: []PendingEntry,
    discarded: bool = false,
};

const PendingEntry = struct {
    prepared: bool = false,
    protocol_prepared: bool = false,
    release_needed: bool = true,
    copy: ?*AsyncShmCopy = null,
    copy_cancel_requested: bool = false,
    snapshot: ?shm.Snapshot = null,
    copy_failed: bool = false,
    dmabuf_reference_held: bool = false,
    event_fd: std.posix.fd_t = -1,
    event_value: u64 = 0,
    handle: ?IoUringLoop.Handle = null,
    completed: bool = false,
    result: i32 = 0,
    cancel_requested: bool = false,
    direct_update: ?SurfaceTree.DirectUpdate = null,
    layer_shell_commit: ?*LayerShell.StagedCommit = null,
    skip_application: bool = false,
};

const RoutedKey = struct {
    device_id: NativeInput.DeviceId,
    key: u32,
};

const RoutedButton = struct {
    seat: *SeatGlobal,
    source: PointerSource,
    button: u32,
};

const PointerSource = union(enum) {
    physical: NativeInput.DeviceId,
    virtual: u64,
};

const GestureKind = enum { swipe, pinch, hold };

const RoutedGesture = struct {
    device_id: NativeInput.DeviceId,
    kind: GestureKind,
};

const PendingAxis = struct {
    active: bool = false,
    time_milliseconds: u32 = 0,
    value: ?i32 = null,
    stopped: bool = false,
    discrete: ?i32 = null,
    value120: ?i32 = null,
};

const TouchRoute = struct {
    device_id: NativeInput.DeviceId,
    native_id: i32,
    protocol_id: i32,
    surface: *CompositorGlobal.Surface,
};

const Hit = struct {
    surface: *CompositorGlobal.Surface,
    root: *CompositorGlobal.Surface,
    local_x: f64,
    local_y: f64,
};

/// Allocates the owner before installing callback contexts, so its address is
/// stable until destroy. The returned server exclusively owns its socket.
pub fn create(allocator: std.mem.Allocator, io: std.Io, options: Options) !*NativeServer {
    const self = try allocator.create(NativeServer);
    errdefer allocator.destroy(self);
    self.allocator = allocator;
    self.io = io;
    self.terminating = false;
    self.event_loop = try EventLoop.init(allocator);
    errdefer self.event_loop.deinit();
    self.repaint_timer = try self.event_loop.addTimer(self, repaintTimer);
    errdefer self.event_loop.removeTimer(self.repaint_timer);
    self.idle_notify_timer = try self.event_loop.addTimer(self, idleNotifyTimer);
    errdefer self.event_loop.removeTimer(self.idle_notify_timer);
    self.session_initialized = false;
    self.drm_device_initialized = false;
    self.drm_listener_installed = false;
    self.native_input_initialized = false;
    self.native_input_device_listener_installed = false;
    var renderer_initialized = false;
    var output_initialized = false;
    errdefer {
        if (self.drm_listener_installed) self.drm_device.clearListener();
        if (output_initialized) switch (self.output) {
            .headless => |*output| output.deinit(),
            .drm => |output| output.?.detach(),
        };
        if (self.drm_device_initialized) {
            self.drm_device.releaseClientBuffers();
            self.drm_device.deinit();
            self.drm_device_initialized = false;
        }
        if (renderer_initialized) self.renderer.deinit();
        if (self.session_initialized) {
            self.session.deinit();
            self.session_initialized = false;
        }
    }
    if (options.output_kind == .drm) {
        try self.session.init(allocator, .{ .io_uring = &self.event_loop });
        self.session_initialized = true;
        try self.drm_device.init(
            allocator,
            io,
            .{ .io_uring = &self.event_loop },
            &self.session,
            options.drm_device_path,
        );
        self.drm_device_initialized = true;
    }
    self.renderer = try Renderer.initForDevice(
        allocator,
        options.renderer_kind,
        if (self.drm_device_initialized) self.drm_device.deviceId() else null,
    );
    renderer_initialized = true;
    self.server = Server.init(allocator);
    errdefer self.server.deinit();
    try self.security_context_global.init(allocator, &self.server, &self.transport);
    errdefer self.security_context_global.deinit();
    try self.fixes_global.init(&self.server);
    errdefer self.fixes_global.deinit();
    try self.shm_global.init(allocator, &self.server);
    errdefer self.shm_global.deinit();
    try self.single_pixel_buffer_global.init(allocator, &self.server);
    errdefer self.single_pixel_buffer_global.deinit();
    try self.compositor_global.init(allocator, &self.server);
    errdefer self.compositor_global.deinit();
    self.surface_tree = SurfaceTree.init(allocator);
    errdefer self.surface_tree.deinit();
    try self.subcompositor_global.init(allocator, &self.server, &self.compositor_global, &self.surface_tree);
    errdefer self.subcompositor_global.deinit();
    try self.xdg_shell.init(allocator, &self.server, &self.surface_tree, .{
        .context = self,
        .surface_size = xdgSurfaceSize,
        .output_bounds = xdgOutputBounds,
    });
    errdefer self.xdg_shell.deinit();
    try self.foreign_toplevel_list_global.init(allocator, &self.server, &self.xdg_shell, &self.security_context_global);
    errdefer self.foreign_toplevel_list_global.deinit();
    try self.gtk_shell_global.init(
        allocator,
        &self.server,
        &self.compositor_global,
        &self.xdg_shell,
    );
    errdefer self.gtk_shell_global.deinit();
    try self.xdg_toplevel_tag_global.init(&self.server, &self.xdg_shell);
    errdefer self.xdg_toplevel_tag_global.deinit();
    try self.xdg_toplevel_icon_global.init(
        allocator,
        &self.server,
        &self.xdg_shell,
        .{ .context = self, .read = readIconBuffer },
    );
    errdefer self.xdg_toplevel_icon_global.deinit();
    try self.xdg_dialog_global.init(allocator, &self.server, &self.xdg_shell);
    errdefer self.xdg_dialog_global.deinit();
    try self.xdg_decoration_global.init(allocator, &self.server, &self.xdg_shell);
    errdefer self.xdg_decoration_global.deinit();
    try self.xdg_system_bell_global.init(&self.server);
    errdefer self.xdg_system_bell_global.deinit();
    try self.linux_dmabuf_global.init(allocator, &self.server, self.renderer.dmabufSourceFormats(), self.renderer.dmabufSourceValidator());
    errdefer self.linux_dmabuf_global.deinit();
    try self.linux_drm_syncobj_global.init(
        allocator,
        io,
        &self.server,
        self.renderer.dmabufDeviceId(),
    );
    errdefer self.linux_drm_syncobj_global.deinit();
    self.output = switch (options.output_kind) {
        .headless => .{ .headless = try HeadlessOutput.initForRenderer(
            allocator,
            options.output_size,
            options.scale,
            options.refresh_millihertz,
            self.renderer.offscreenAccess(),
        ) },
        .drm => drm: {
            const output = for (self.drm_device.outputs()) |candidate| {
                if (candidate.enabled) break candidate;
            } else return error.NoEnabledDrmOutput;
            try output.attach(drmOutputListener(self), self.renderer.dmabufAccess());
            break :drm .{ .drm = @as(?*DrmOutput, output) };
        },
    };
    output_initialized = true;
    self.commit_timing_clock = try commitTimingClock(self.output.presentationClockId());
    self.commit_timing_timer = switch (self.commit_timing_clock) {
        .awake => try self.event_loop.addTimer(self, commitTimingTimer),
        .real => try self.event_loop.addWallTimer(self, commitTimingTimer),
        else => unreachable,
    };
    self.commit_timing_armed_target = null;
    errdefer self.event_loop.removeTimer(self.commit_timing_timer);
    try self.output_global.init(allocator, &self.server, .{
        .mode_size = self.output.modeSize(),
        .logical_size = self.output.logicalSize(),
        .physical_size = self.output.physicalSize(),
        .refresh_millihertz = self.output.refreshMillihertz(),
        .scale = self.output.scale().ceil() catch return error.InvalidScale,
        .name = self.output.name(),
        .description = self.output.description(),
        .make = self.output.make(),
        .model = self.output.model(),
    });
    errdefer self.output_global.deinit();
    try self.layer_shell.init(
        allocator,
        &self.server,
        &self.surface_tree,
        &self.output_global,
        &self.security_context_global,
        .{
            .context = self,
            .changed = layerShellChanged,
            .deactivated = layerShellDeactivated,
            .surface_size = xdgSurfaceSize,
        },
    );
    errdefer self.layer_shell.deinit();
    try self.xdg_output_global.init(
        allocator,
        &self.server,
        &self.output_global,
    );
    errdefer self.xdg_output_global.deinit();
    try self.screencopy_global.init(
        allocator,
        &self.server,
        self.event_loop.ioLoop(),
        &self.output_global,
        &self.security_context_global,
        .{
            .context = self,
            .constraints = screencopyConstraints,
            .schedule = scheduleScreencopy,
            .capture = captureScreencopy,
            .complete = completeScreencopy,
        },
    );
    errdefer self.screencopy_global.deinit();
    try self.presentation_global.init(
        allocator,
        &self.server,
        &self.compositor_global,
        self.output.presentationClockId(),
    );
    errdefer self.presentation_global.deinit();
    try self.content_type_global.init(allocator, &self.server, &self.compositor_global);
    errdefer self.content_type_global.deinit();
    try self.color_representation_global.init(allocator, &self.server, &self.compositor_global);
    errdefer self.color_representation_global.deinit();
    try self.alpha_modifier_global.init(allocator, &self.server, &self.compositor_global);
    errdefer self.alpha_modifier_global.deinit();
    try self.background_effect_global.init(allocator, &self.server, &self.compositor_global);
    errdefer self.background_effect_global.deinit();
    try self.tearing_control_global.init(allocator, &self.server, &self.compositor_global);
    errdefer self.tearing_control_global.deinit();
    try self.fifo_global.init(allocator, &self.server, &self.compositor_global);
    errdefer self.fifo_global.deinit();
    try self.commit_timing_global.init(allocator, &self.server, &self.compositor_global);
    errdefer self.commit_timing_global.deinit();
    self.pointer_cursor.init(allocator, .{
        .context = self,
        .repaint = cursorRepaint,
    });
    errdefer self.pointer_cursor.deinit();
    try self.seat_global.init(
        allocator,
        &self.server,
        "default",
        0,
        self.pointer_cursor.handler(),
    );
    errdefer self.seat_global.deinit();
    try self.transient_seat_global.init(
        allocator,
        &self.server,
        &self.security_context_global,
    );
    errdefer self.transient_seat_global.deinit();
    try self.virtual_keyboard_global.init(
        allocator,
        io,
        &self.server,
        &self.seat_global,
        &self.transient_seat_global,
        &self.security_context_global,
        virtualKeyboardListener(self),
    );
    errdefer self.virtual_keyboard_global.deinit();
    try self.virtual_pointer_global.init(
        allocator,
        &self.server,
        &self.seat_global,
        &self.transient_seat_global,
        &self.output_global,
        &self.security_context_global,
        virtualPointerListener(self),
    );
    errdefer self.virtual_pointer_global.deinit();
    var activation_token_key: [std.crypto.auth.hmac.sha2.HmacSha256.key_length]u8 = undefined;
    defer @memset(&activation_token_key, 0);
    try io.randomSecure(&activation_token_key);
    try self.xdg_activation_global.init(
        allocator,
        &self.server,
        &self.compositor_global,
        &self.seat_global,
        activation_token_key,
        .{ .context = self, .now = idleNotifyNow },
        .{ .context = self, .requested = xdgActivationRequested },
    );
    errdefer self.xdg_activation_global.deinit();
    try self.idle_notify_global.init(
        allocator,
        &self.server,
        &self.seat_global,
        .{
            .context = self,
            .now = idleNotifyNow,
            .schedule = scheduleIdleNotify,
        },
    );
    errdefer self.idle_notify_global.deinit();
    try self.idle_inhibit_global.init(
        allocator,
        &self.server,
        &self.compositor_global,
    );
    errdefer self.idle_inhibit_global.deinit();
    try self.keyboard_shortcuts_inhibit_global.init(
        allocator,
        &self.server,
        &self.compositor_global,
        &self.seat_global,
    );
    errdefer self.keyboard_shortcuts_inhibit_global.deinit();
    try self.relative_pointer_global.init(
        allocator,
        &self.server,
        &self.seat_global,
    );
    errdefer self.relative_pointer_global.deinit();
    try self.pointer_warp_global.init(
        &self.server,
        &self.seat_global,
        .{
            .context = self,
            .surface_size = xdgSurfaceSize,
            .warp = pointerWarp,
        },
    );
    errdefer self.pointer_warp_global.deinit();
    try self.pointer_gestures_global.init(
        allocator,
        &self.server,
        &self.seat_global,
    );
    errdefer self.pointer_gestures_global.deinit();
    try self.tablet_global.init(
        allocator,
        &self.server,
        &self.seat_global,
        .{
            .context = self,
            .surface_coordinates = tabletSurfaceCoordinates,
            .repaint = cursorRepaint,
        },
    );
    errdefer self.tablet_global.deinit();
    try self.cursor_shape_global.init(
        allocator,
        &self.server,
        &self.seat_global,
        &self.pointer_cursor,
        &self.tablet_global,
    );
    errdefer self.cursor_shape_global.deinit();
    try self.data_device_global.init(allocator, &self.server, &self.seat_global);
    errdefer self.data_device_global.deinit();
    try self.primary_selection_global.init(allocator, &self.server, &self.seat_global);
    errdefer self.primary_selection_global.deinit();
    try self.data_control_global.init(
        allocator,
        &self.server,
        &self.seat_global,
        &self.data_device_global,
        &self.primary_selection_global,
        &self.security_context_global,
    );
    errdefer self.data_control_global.deinit();
    self.input_paint_entries = .empty;
    self.routed_keys = .empty;
    self.routed_buttons = .empty;
    self.unattributed_keys = .empty;
    self.keyboard_enter_keys = .empty;
    self.touch_routes = .empty;
    self.pointer_axes = .{ .{}, .{} };
    self.pointer_axis_source = null;
    self.active_gesture = null;
    self.keyboard_available = false;
    self.pointer_available = false;
    self.touch_available = false;
    const mode_size = self.output.modeSize();
    self.pointer_physical_x = @as(f64, @floatFromInt(mode_size.width)) / 2;
    self.pointer_physical_y = @as(f64, @floatFromInt(mode_size.height)) / 2;
    self.syncPointerCursorPosition();
    self.keyboard_modifiers = .{};
    self.last_keyboard_serial = 0;
    self.exclusive_focus_active = false;
    self.exclusive_focus_restore = null;
    self.next_touch_id = 1;
    self.surfaces = .empty;
    self.pending = .empty;
    self.frame_callbacks = .empty;
    self.presentation_pending = .empty;
    self.presentation_submitted = .empty;
    self.next_surface_sample_tag = 1;
    errdefer self.deinitInputState();
    errdefer if (self.native_input_initialized) {
        if (self.native_input_device_listener_installed) {
            self.native_input.clearDeviceListener();
            self.native_input_device_listener_installed = false;
        }
        self.native_input.deinit();
        self.native_input_initialized = false;
    };
    if (options.output_kind == .drm) {
        try self.native_input.init(
            allocator,
            io,
            .{ .io_uring = &self.event_loop },
            &self.session,
            mode_size,
            nativeInputListener(self),
        );
        self.native_input_initialized = true;
        self.native_input.setDeviceListener(nativeInputDeviceListener(self));
        self.native_input_device_listener_installed = true;
        self.native_input.setPointerPosition(self.pointer_physical_x, self.pointer_physical_y);
    }
    try self.fractional_scale_global.init(
        allocator,
        &self.server,
        self.output.scale().numerator,
    );
    errdefer self.fractional_scale_global.deinit();
    try self.viewporter_global.init(allocator, &self.server);
    errdefer self.viewporter_global.deinit();

    const selection = try selectSocket(allocator, options);
    errdefer {
        allocator.free(selection.name);
        allocator.free(selection.path);
    }
    const listener = try bindListener(selection.path, options.listen_backlog);
    var listener_fd_owned = true;
    errdefer {
        if (listener_fd_owned) _ = linux.close(listener);
        _ = std.c.unlink(selection.path.ptr);
    }
    // Keep the transport ownership transfer after every fallible startup
    // operation: its listener can only be drained by the normal destroy path.
    if (options.output_kind == .drm) try self.repaint_timer.arm(1, 0);
    listener_fd_owned = false;
    try self.transport.init(allocator, self.event_loop.ioLoop(), &self.server, listener);

    self.display_name = selection.name;
    self.socket_path = selection.path;
    self.frame_count = 0;
    self.repaint_needed = options.output_kind == .drm;
    self.fifo_progress_needed = false;
    self.output_busy_retries = 0;
    self.event_loop.setAfterPlatformHook(self, afterPlatform);
    self.event_loop.setEndTurnHook(self, endTurn);
    if (self.drm_device_initialized) {
        self.drm_device.setListener(drmDeviceListener(self));
        self.drm_listener_installed = true;
    }
    return self;
}

pub fn displayName(self: *const NativeServer) []const u8 {
    return self.display_name;
}

/// Runs EventLoop's native submit/wait/drain loop until terminate is called.
pub fn run(self: *NativeServer) !void {
    try self.installSignals();
    defer self.uninstallSignals();
    try self.event_loop.run();
}

pub fn terminate(self: *NativeServer) void {
    self.event_loop.quit();
}

fn installSignals(self: *NativeServer) !void {
    std.debug.assert(!self.signals_installed);
    self.signal_mask = std.posix.sigemptyset();
    std.posix.sigaddset(&self.signal_mask, .INT);
    std.posix.sigaddset(&self.signal_mask, .TERM);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &self.signal_mask, &self.previous_signal_mask);
    var mask_installed = true;
    errdefer if (mask_installed)
        std.posix.sigprocmask(std.posix.SIG.SETMASK, &self.previous_signal_mask, null);
    self.signal_fd = try std.posix.signalfd(-1, &self.signal_mask, linux.SFD.CLOEXEC);
    errdefer {
        _ = linux.close(self.signal_fd);
        self.signal_fd = -1;
    }
    self.signal_handle = try self.event_loop.ioLoop().queue(
        self,
        signalComplete,
        self,
        prepareSignalRead,
    );
    self.signals_installed = true;
    mask_installed = false;
}

fn prepareSignalRead(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    sqe.prep_read(self.signal_fd, std.mem.asBytes(&self.signal_info), 0);
}

fn signalComplete(
    context: *anyopaque,
    _: *IoUringLoop,
    completion: IoUringLoop.Completion,
) !void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.signal_handle = null;
    if (completion.result == -@as(i32, @intFromEnum(linux.E.CANCELED))) return;
    if (completion.result != @sizeOf(linux.signalfd_siginfo)) return error.SignalReadFailed;
    if (self.signal_info.signo == @intFromEnum(std.posix.SIG.INT) or
        self.signal_info.signo == @intFromEnum(std.posix.SIG.TERM))
    {
        self.terminate();
    }
}

fn uninstallSignals(self: *NativeServer) void {
    if (!self.signals_installed) return;
    if (self.signal_handle) |handle| {
        self.event_loop.ioLoop().cancel(handle) catch
            @panic("failed to cancel native compositor signal read");
        while (self.event_loop.ioLoop().isActive(handle))
            self.event_loop.ioLoop().runOnce() catch
                @panic("failed to drain native compositor signal read");
        self.signal_handle = null;
    }
    _ = linux.close(self.signal_fd);
    self.signal_fd = -1;
    std.posix.sigprocmask(std.posix.SIG.SETMASK, &self.previous_signal_mask, null);
    self.signals_installed = false;
}

pub fn inspectFrame(self: *const NativeServer) FrameInspection {
    return .{
        .size = self.output.modeSize(),
        .pixels = switch (self.output) {
            .headless => |output| output.pixels,
            .drm => &.{},
        },
        .frame_count = self.frame_count,
    };
}

pub fn pixel(self: *const NativeServer, x: u32, y: u32) u32 {
    return switch (self.output) {
        .headless => |output| output.pixel(x, y),
        .drm => unreachable,
    };
}

/// Cancels and drains all ring users before freeing callback storage and the
/// EventLoop. This may submit/wait for cancellation CQEs, but never sleeps.
pub fn destroy(self: *NativeServer) void {
    self.terminating = true;
    if (self.exclusive_focus_restore) |surface| {
        surface.unreference();
        self.exclusive_focus_restore = null;
    }
    self.screencopy_global.shutdown();
    self.event_loop.clearAfterPlatformHook();
    self.event_loop.clearEndTurnHook();
    self.event_loop.removeTimer(self.repaint_timer);
    self.event_loop.removeTimer(self.idle_notify_timer);
    self.event_loop.removeTimer(self.commit_timing_timer);
    if (self.drm_listener_installed) {
        self.drm_device.clearListener();
        self.drm_listener_installed = false;
    }
    if (self.native_input_initialized) {
        if (self.native_input_device_listener_installed) {
            self.native_input.clearDeviceListener();
            self.native_input_device_listener_installed = false;
        }
        self.native_input.deinit();
        self.native_input_initialized = false;
    }
    switch (self.output) {
        .headless => {},
        .drm => |*output| if (output.*) |drm_output| {
            drm_output.detach();
            output.* = null;
        },
    }
    for (self.pending.items) |pending| {
        pending.discarded = true;
        self.cancelPending(pending) catch @panic("failed to cancel native transaction");
    }
    self.transport.shutdown() catch {};
    while (!self.transport.readyToDeinit() or
        self.hasPendingIo())
    {
        self.event_loop.ioLoop().runOnce() catch @panic("failed to drain native compositor I/O");
        self.transport.dispatch() catch {};
    }
    self.transport.dispatch() catch {};
    self.transport.deinit();
    while (self.pending.items.len != 0) self.destroyPending(0);
    self.pending.deinit(self.allocator);
    self.discardFrameCallbacks();
    self.discardPresentationFeedbacks();
    self.deinitInputState();

    while (self.compositor_global.popTransaction()) |transaction_value| {
        var transaction = transaction_value;
        transaction.releaseBuffers();
        transaction.deinit();
    }
    for (self.surfaces.items) |state| {
        self.output_global.setSurfaceVisible(state.surface, false) catch {};
        state.deinit(self.allocator);
    }
    self.surfaces.deinit(self.allocator);
    self.viewporter_global.deinit();
    self.fractional_scale_global.deinit();
    self.data_control_global.deinit();
    self.primary_selection_global.deinit();
    self.data_device_global.deinit();
    self.cursor_shape_global.deinit();
    self.tablet_global.deinit();
    self.pointer_gestures_global.deinit();
    self.pointer_warp_global.deinit();
    self.relative_pointer_global.deinit();
    self.keyboard_shortcuts_inhibit_global.deinit();
    self.idle_inhibit_global.deinit();
    self.idle_notify_global.deinit();
    self.xdg_activation_global.deinit();
    self.virtual_pointer_global.deinit();
    self.virtual_keyboard_global.deinit();
    self.transient_seat_global.deinit();
    self.seat_global.deinit();
    self.pointer_cursor.deinit();
    self.commit_timing_global.deinit();
    self.fifo_global.deinit();
    self.tearing_control_global.deinit();
    self.background_effect_global.deinit();
    self.alpha_modifier_global.deinit();
    self.color_representation_global.deinit();
    self.content_type_global.deinit();
    self.presentation_global.deinit();
    self.screencopy_global.deinit();
    self.xdg_output_global.deinit();
    self.layer_shell.deinit();
    self.output_global.deinit();
    self.xdg_system_bell_global.deinit();
    self.xdg_decoration_global.deinit();
    self.xdg_dialog_global.deinit();
    self.xdg_toplevel_icon_global.deinit();
    self.xdg_toplevel_tag_global.deinit();
    self.gtk_shell_global.deinit();
    self.foreign_toplevel_list_global.deinit();
    self.xdg_shell.deinit();
    self.subcompositor_global.deinit();
    self.surface_tree.deinit();
    self.compositor_global.deinit();
    self.single_pixel_buffer_global.deinit();
    self.shm_global.deinit();
    self.linux_drm_syncobj_global.deinit();
    self.linux_dmabuf_global.deinit();
    self.fixes_global.deinit();
    self.security_context_global.deinit();
    self.server.deinit();
    switch (self.output) {
        .headless => |*output| output.deinit(),
        .drm => {},
    }
    if (self.drm_device_initialized) {
        self.drm_device.releaseClientBuffers();
        self.drm_device.deinit();
        self.drm_device_initialized = false;
    }
    self.renderer.deinit();
    if (self.session_initialized) {
        self.session.deinit();
        self.session_initialized = false;
    }
    self.event_loop.deinit();
    _ = std.c.unlink(self.socket_path.ptr);
    self.allocator.free(self.socket_path);
    self.allocator.free(self.display_name);
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

fn hasPendingIo(self: *const NativeServer) bool {
    for (self.pending.items) |pending| for (pending.entries) |entry|
        if (entry.handle != null or (entry.copy != null and !entry.copy.?.isTerminal())) return true;
    return self.screencopy_global.hasPendingIo();
}

fn afterPlatform(context: *anyopaque, _: *EventLoop) !void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    try self.transport.dispatch();
    try self.tablet_global.pruneDeadFocus();
    try self.intakeTransactions();
    try self.cancelDeadTransactions();
    try self.progressTransactions();
    self.discardDeadFrameCallbacks();
    const pruned = self.pruneSurfaces();
    if (pruned or self.surface_tree.needsRedraw())
        try self.refreshInputFocus(inputTime(self));
    if (pruned or self.surface_tree.needsRedraw() or self.repaint_needed)
        try self.renderScene(null);
    // A successful latch may be the only event that releases a blocked wait.
    while (self.fifo_progress_needed) {
        self.fifo_progress_needed = false;
        try self.progressTransactions();
    }
    self.refreshIdleInhibition();
    self.xdg_activation_global.expireTokens();
    try self.scheduleCommitTiming();
}

fn commitTimingTimer(context: *anyopaque, _: *EventLoop, _: u64) !void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    // The protocol range exceeds EventLoop's bounded relative delay. Clear
    // the deduplication key so a clamped intermediate wake can arm the next
    // chunk. The after-platform phase has already applied any due commits.
    self.commit_timing_armed_target = null;
    try self.scheduleCommitTiming();
}

fn drmOutputListener(self: *NativeServer) DrmOutput.Listener {
    return .{
        .context = self,
        .ready = drmOutputReady,
        .presented = drmOutputPresented,
        .discarded = drmOutputDiscarded,
    };
}

fn drmOutputReady(context: *anyopaque) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (self.repaint_needed) self.scheduleRepaint(0);
}

fn drmOutputPresented(context: *anyopaque, info: presentation.Info) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.finishSubmittedPresentation(info);
}

fn drmOutputDiscarded(context: *anyopaque) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.discardSubmittedPresentation();
    self.repaint_needed = true;
}

fn drmDeviceListener(self: *NativeServer) DrmDevice.Listener {
    return .{
        .context = self,
        .added = drmOutputAdded,
        .removing = drmOutputRemoving,
        .failed = drmDeviceFailed,
        .activated = drmDeviceActivated,
        .deactivating = drmDeviceDeactivating,
        .changed = drmOutputChanged,
    };
}

fn drmOutputAdded(_: *anyopaque, _: *DrmOutput) void {}

fn drmOutputRemoving(context: *anyopaque, removed: *DrmOutput) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    const selected = switch (self.output) {
        .headless => return,
        .drm => |output| output,
    } orelse return;
    if (selected != removed) return;
    self.terminating = true;
    self.screencopy_global.outputRemoved();
    removed.detach();
    self.output.drm = null;
    self.terminate();
}

fn drmDeviceFailed(context: *anyopaque) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.terminate();
}

fn drmDeviceActivated(context: *anyopaque) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.repaint_needed = true;
    self.scheduleRepaint(0);
}

fn drmDeviceDeactivating(context: *anyopaque) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.repaint_needed = true;
}

fn drmOutputChanged(_: *anyopaque, _: *DrmOutput) void {}

fn nativeInputListener(self: *NativeServer) NativeInput.Listener {
    return .{
        .context = self,
        .close = nativeInputClose,
        .keyboard_available = nativeKeyboardAvailable,
        .keyboard_keymap = nativeKeyboardKeymap,
        .keyboard_enter = nativeKeyboardEnter,
        .keyboard_key = nativeKeyboardKey,
        .keyboard_modifiers = nativeKeyboardModifiers,
        .keyboard_repeat_info = nativeKeyboardRepeatInfo,
        .pointer_available = nativePointerAvailable,
        .pointer_motion = nativePointerMotion,
        .pointer_relative_motion = nativePointerRelativeMotion,
        .pointer_button = nativePointerButton,
        .pointer_axis = nativePointerAxis,
        .pointer_frame = nativePointerFrame,
        .pointer_axis_source = nativePointerAxisSource,
        .pointer_axis_stop = nativePointerAxisStop,
        .pointer_axis_discrete = nativePointerAxisDiscrete,
        .pointer_axis_value120 = nativePointerAxisValue120,
        .swipe_begin = nativeSwipeBegin,
        .swipe_update = nativeSwipeUpdate,
        .swipe_end = nativeSwipeEnd,
        .pinch_begin = nativePinchBegin,
        .pinch_update = nativePinchUpdate,
        .pinch_end = nativePinchEnd,
        .hold_begin = nativeHoldBegin,
        .hold_end = nativeHoldEnd,
        .tablet_tool_proximity = nativeTabletToolProximity,
        .tablet_tool_axis = nativeTabletToolAxis,
        .tablet_tool_tip = nativeTabletToolTip,
        .tablet_tool_button = nativeTabletToolButton,
        .tablet_pad_button = nativeTabletPadButton,
        .tablet_pad_ring = nativeTabletPadRing,
        .tablet_pad_strip = nativeTabletPadStrip,
        .tablet_pad_dial = nativeTabletPadDial,
        .touch_available = nativeTouchAvailable,
        .touch_down = nativeTouchDown,
        .touch_up = nativeTouchUp,
        .touch_motion = nativeTouchMotion,
        .touch_frame = nativeTouchFrame,
        .touch_cancel = nativeTouchCancel,
    };
}

fn nativeInputDeviceListener(self: *NativeServer) NativeInput.DeviceListener {
    return .{
        .context = self,
        .added = nativeInputDeviceAdded,
        .removed = nativeInputDeviceRemoved,
    };
}

fn virtualKeyboardListener(self: *NativeServer) VirtualKeyboardGlobal.Listener {
    return .{
        .context = self,
        .capability_changed = virtualKeyboardCapabilityChanged,
        .activity = virtualInputActivity,
        .failed = virtualInputFailed,
    };
}

fn virtualPointerListener(self: *NativeServer) VirtualPointerGlobal.Listener {
    return .{
        .context = self,
        .event = virtualPointerEvent,
        .capability_changed = virtualPointerCapabilityChanged,
        .failed = virtualInputFailed,
    };
}

fn virtualInputActivity(context: *anyopaque) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
}

fn virtualInputFailed(context: *anyopaque) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.terminate();
}

fn xdgActivationRequested(
    context: *anyopaque,
    surface: *CompositorGlobal.Surface,
    proven_interaction: bool,
) !void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    // Attention/urgency publication is deferred to native workspace parity.
    // Unproven requests must never steal focus in the meantime.
    if (!proven_interaction) return;
    const root = if (self.surface_tree.find(surface)) |node|
        SurfaceTree.root(node).surface
    else
        surface;
    if (!self.xdg_shell.isToplevelSurface(root)) return;
    if (!self.surfaceActive(root)) {
        _ = self.xdg_shell.deferActivation(root);
        return;
    }
    try self.activateToplevel(root);
}

fn virtualKeyboardCapabilityChanged(context: *anyopaque, seat: *SeatGlobal) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.refreshKeyboardCapability(seat) catch self.terminate();
}

fn virtualPointerCapabilityChanged(context: *anyopaque, seat: *SeatGlobal) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (seat != &self.seat_global and
        !seat.hasCapability(SeatGlobal.Capability.pointer))
    {
        // A retiring transient seat can outlive routing availability, but no
        // NativeServer route may outlive the SeatGlobal allocation.
        self.removeRoutedButtonsForSeat(seat);
        std.debug.assert(!self.seatHasRoutedButtons(seat));
    }
    if (!self.inputRoutingAvailable()) return;
    self.refreshPointerCapability(seat) catch self.terminate();
}

fn inputRoutingAvailable(self: *const NativeServer) bool {
    if (self.terminating) return false;
    return switch (self.output) {
        .headless => true,
        .drm => |output| output != null,
    };
}

fn nativeInputClose(context: *anyopaque) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.terminate();
}

fn nativeKeyboardAvailable(context: *anyopaque, available: bool) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.keyboard_available = available;
    if (!available) {
        self.seat_global.clearPhysicalKeys(0) catch return self.terminate();
        self.routed_keys.clearRetainingCapacity();
        self.unattributed_keys.clearRetainingCapacity();
        self.keyboard_modifiers = .{};
        self.seat_global.setPhysicalModifiers(
            self.server.nextSerial(),
            0,
            0,
            0,
            0,
        ) catch return self.terminate();
    }
    self.refreshSeatCapabilities() catch self.terminate();
    self.refreshKeyboardCapability(&self.seat_global) catch self.terminate();
}

fn nativeKeyboardKeymap(
    context: *anyopaque,
    _: ?NativeInput.DeviceId,
    format: NativeInput.KeyboardKeymapFormat,
    fd: std.posix.fd_t,
    size: u32,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.seat_global.keyboardKeymap(@intFromEnum(format), fd, size) catch self.terminate();
}

fn nativeKeyboardEnter(context: *anyopaque, keys: []const u32) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.unattributed_keys.clearRetainingCapacity();
    self.unattributed_keys.appendSlice(self.allocator, keys) catch return self.terminate();
    self.reenterKeyboardFocus() catch self.terminate();
}

fn nativeKeyboardKey(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    time: u32,
    key: u32,
    state: NativeInput.KeyState,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
    self.routeKeyboardKey(device_id, time, key, state) catch self.terminate();
}

fn nativeKeyboardModifiers(
    context: *anyopaque,
    _: ?NativeInput.DeviceId,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.keyboard_modifiers = .{
        .depressed = depressed,
        .latched = latched,
        .locked = locked,
        .group = group,
    };
    self.seat_global.setPhysicalModifiers(
        if (self.last_keyboard_serial != 0)
            self.last_keyboard_serial
        else
            self.server.nextSerial(),
        depressed,
        latched,
        locked,
        group,
    ) catch self.terminate();
}

fn nativeKeyboardRepeatInfo(
    context: *anyopaque,
    _: ?NativeInput.DeviceId,
    rate: i32,
    delay: i32,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.seat_global.keyboardRepeatInfo(rate, delay) catch self.terminate();
}

fn nativePointerAvailable(context: *anyopaque, available: bool) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.pointer_available = available;
    if (!available) {
        self.cancelActiveGesture() catch return self.terminate();
        self.releasePhysicalButtons() catch return self.terminate();
        self.pointer_axes = .{ .{}, .{} };
        self.pointer_axis_source = null;
    }
    self.refreshSeatCapabilities() catch self.terminate();
    self.refreshPointerCapability(&self.seat_global) catch self.terminate();
}

fn nativePointerMotion(
    context: *anyopaque,
    _: NativeInput.DeviceId,
    time: u32,
    x: f64,
    y: f64,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.idle_notify_global.notifyActivity();
    const size = self.output.modeSize();
    self.pointer_physical_x = clampPointerCoordinate(x, size.width);
    self.pointer_physical_y = clampPointerCoordinate(y, size.height);
    if (self.native_input_initialized)
        self.native_input.setPointerPosition(self.pointer_physical_x, self.pointer_physical_y);
    self.syncPointerCursorPosition();
    _ = self.refreshPointerFocus(&self.seat_global, time) catch return self.terminate();
}

fn nativePointerRelativeMotion(
    context: *anyopaque,
    _: NativeInput.DeviceId,
    time_microseconds: u64,
    dx: f64,
    dy: f64,
    dx_unaccelerated: f64,
    dy_unaccelerated: f64,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.idle_notify_global.notifyActivity();
    self.relative_pointer_global.motion(
        time_microseconds,
        dx,
        dy,
        dx_unaccelerated,
        dy_unaccelerated,
    ) catch return self.terminate();
    const size = self.output.modeSize();
    self.pointer_physical_x = clampPointerCoordinate(self.pointer_physical_x + dx, size.width);
    self.pointer_physical_y = clampPointerCoordinate(self.pointer_physical_y + dy, size.height);
    if (self.native_input_initialized)
        self.native_input.setPointerPosition(self.pointer_physical_x, self.pointer_physical_y);
    self.syncPointerCursorPosition();
    _ = self.refreshPointerFocus(
        &self.seat_global,
        @truncate(time_microseconds / std.time.us_per_ms),
    ) catch
        return self.terminate();
}

fn pointerWarp(
    context: *anyopaque,
    surface: *const CompositorGlobal.Surface,
    x: f64,
    y: f64,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    const node = self.surface_tree.find(surface) orelse return;
    const position = SurfaceTree.globalPosition(node);
    const logical_x = @as(f64, @floatFromInt(position.x)) + x;
    const logical_y = @as(f64, @floatFromInt(position.y)) + y;
    if (!self.seat_global.warpPointer(
        surface,
        fixedFromDouble(x),
        fixedFromDouble(y),
    )) return;
    self.pointer_physical_x = logicalToPhysicalScale(logical_x, self.output.scale());
    self.pointer_physical_y = logicalToPhysicalScale(logical_y, self.output.scale());
    if (self.native_input_initialized)
        self.native_input.setPointerPosition(self.pointer_physical_x, self.pointer_physical_y);
    self.syncPointerCursorPosition();
}

fn nativePointerButton(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    time: u32,
    button: u32,
    state: NativeInput.ButtonState,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.idle_notify_global.notifyActivity();
    self.routePointerButton(device_id, time, button, state) catch self.terminate();
}

fn nativePointerAxis(
    context: *anyopaque,
    _: NativeInput.DeviceId,
    time: u32,
    axis: NativeInput.Axis,
    value: i32,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.idle_notify_global.notifyActivity();
    const pending = self.pendingAxis(axis) orelse return;
    pending.active = true;
    pending.time_milliseconds = time;
    pending.value = value;
}

fn nativePointerAxisSource(
    context: *anyopaque,
    _: NativeInput.DeviceId,
    source: NativeInput.AxisSource,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.idle_notify_global.notifyActivity();
    self.pointer_axis_source = @intFromEnum(source);
}

fn nativePointerAxisStop(
    context: *anyopaque,
    _: NativeInput.DeviceId,
    time: u32,
    axis: NativeInput.Axis,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.idle_notify_global.notifyActivity();
    const pending = self.pendingAxis(axis) orelse return;
    pending.active = true;
    pending.time_milliseconds = time;
    pending.stopped = true;
}

fn nativePointerAxisDiscrete(
    context: *anyopaque,
    _: NativeInput.DeviceId,
    axis: NativeInput.Axis,
    value: i32,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.idle_notify_global.notifyActivity();
    const pending = self.pendingAxis(axis) orelse return;
    pending.active = true;
    pending.discrete = value;
}

fn nativePointerAxisValue120(
    context: *anyopaque,
    _: NativeInput.DeviceId,
    axis: NativeInput.Axis,
    value: i32,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.idle_notify_global.notifyActivity();
    const pending = self.pendingAxis(axis) orelse return;
    pending.active = true;
    pending.value120 = value;
}

fn nativePointerFrame(context: *anyopaque, _: NativeInput.DeviceId) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.flushPointerFrame() catch self.terminate();
}

fn nativeTouchAvailable(context: *anyopaque, available: bool) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.touch_available = available;
    if (!available) self.cancelTouches() catch self.terminate();
    self.refreshSeatCapabilities() catch self.terminate();
}

fn nativeTouchDown(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    time: u32,
    native_id: i32,
    x: f64,
    y: f64,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.idle_notify_global.notifyActivity();
    self.routeTouchDown(device_id, time, native_id, x, y) catch self.terminate();
}

fn nativeTouchUp(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    time: u32,
    native_id: i32,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
    self.routeTouchUp(device_id, time, native_id) catch self.terminate();
}

fn nativeTouchMotion(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    time: u32,
    native_id: i32,
    x: f64,
    y: f64,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.idle_notify_global.notifyActivity();
    self.routeTouchMotion(device_id, time, native_id, x, y) catch self.terminate();
}

fn nativeTouchFrame(context: *anyopaque, _: NativeInput.DeviceId) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.seat_global.touchFrame() catch self.terminate();
}

fn nativeTouchCancel(context: *anyopaque, _: NativeInput.DeviceId) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.cancelTouches() catch self.terminate();
}

fn nativeInputDeviceAdded(context: *anyopaque, device: NativeInput.DeviceInfo) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    switch (device.device_type) {
        .tablet => self.tablet_global.addTablet(
            device,
            self.native_input.tabletInfo(device.id) orelse return,
        ) catch self.terminate(),
        .tablet_pad => self.tablet_global.addPad(
            device,
            self.native_input.tabletPadInfo(device.id) orelse return,
        ) catch self.terminate(),
        else => {},
    }
}

fn nativeInputDeviceRemoved(context: *anyopaque, device_id: NativeInput.DeviceId) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (self.active_gesture) |gesture| if (gesture.device_id == device_id)
        self.cancelActiveGesture() catch return self.terminate();
    self.tablet_global.removePad(device_id) catch return self.terminate();
    self.tablet_global.removeTablet(device_id) catch return self.terminate();
    self.releaseDeviceKeys(device_id) catch return self.terminate();
    self.releaseDeviceButtons(device_id) catch return self.terminate();
    for (self.touch_routes.items) |route| if (route.device_id == device_id) {
        self.cancelTouches() catch self.terminate();
        return;
    };
}

fn nativeSwipeBegin(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, fingers: u32) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
    self.beginGesture(device_id, time, fingers, .swipe) catch self.terminate();
}

fn nativeSwipeUpdate(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, dx: f64, dy: f64) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
    const gesture = self.active_gesture orelse return;
    if (gesture.device_id != device_id or gesture.kind != .swipe) return;
    self.pointer_gestures_global.updateSwipe(time, dx, dy) catch self.terminate();
}

fn nativeSwipeEnd(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, cancelled: bool) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
    self.endGesture(device_id, time, .swipe, cancelled) catch self.terminate();
}

fn nativePinchBegin(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, fingers: u32) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
    self.beginGesture(device_id, time, fingers, .pinch) catch self.terminate();
}

fn nativePinchUpdate(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, dx: f64, dy: f64, scale: f64, rotation: f64) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
    const gesture = self.active_gesture orelse return;
    if (gesture.device_id != device_id or gesture.kind != .pinch) return;
    self.pointer_gestures_global.updatePinch(
        time,
        dx,
        dy,
        scale,
        rotation,
    ) catch self.terminate();
}

fn nativePinchEnd(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, cancelled: bool) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
    self.endGesture(device_id, time, .pinch, cancelled) catch self.terminate();
}

fn nativeHoldBegin(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, fingers: u32) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
    self.beginGesture(device_id, time, fingers, .hold) catch self.terminate();
}

fn nativeHoldEnd(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, cancelled: bool) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
    self.endGesture(device_id, time, .hold, cancelled) catch self.terminate();
}

fn beginGesture(
    self: *NativeServer,
    device_id: NativeInput.DeviceId,
    time: u32,
    fingers: u32,
    kind: GestureKind,
) !void {
    try self.cancelActiveGesture();
    self.active_gesture = .{ .device_id = device_id, .kind = kind };
    switch (kind) {
        .swipe => try self.pointer_gestures_global.beginSwipe(time, fingers),
        .pinch => try self.pointer_gestures_global.beginPinch(time, fingers),
        .hold => try self.pointer_gestures_global.beginHold(time, fingers),
    }
}

fn endGesture(
    self: *NativeServer,
    device_id: NativeInput.DeviceId,
    time: u32,
    kind: GestureKind,
    cancelled: bool,
) !void {
    const gesture = self.active_gesture orelse return;
    if (gesture.device_id != device_id or gesture.kind != kind) return;
    self.active_gesture = null;
    try self.sendGestureEnd(kind, time, cancelled);
}

fn cancelActiveGesture(self: *NativeServer) !void {
    const gesture = self.active_gesture orelse return;
    self.active_gesture = null;
    try self.sendGestureEnd(gesture.kind, 0, true);
}

fn sendGestureEnd(
    self: *NativeServer,
    kind: GestureKind,
    time: u32,
    cancelled: bool,
) !void {
    switch (kind) {
        .swipe => try self.pointer_gestures_global.endSwipe(time, cancelled),
        .pinch => try self.pointer_gestures_global.endPinch(time, cancelled),
        .hold => try self.pointer_gestures_global.endHold(time, cancelled),
    }
}

fn nativeTabletToolProximity(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    tool_id: NativeInput.TabletToolId,
    time: u32,
    x: f64,
    y: f64,
    in_proximity: bool,
    axes: NativeInput.TabletToolAxes,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.idle_notify_global.notifyActivity();
    const info = self.native_input.tabletToolInfo(tool_id) orelse return;
    const focus = if (in_proximity)
        self.tabletFocus(self.physicalToLogical(x), self.physicalToLogical(y)) catch
            return self.terminate()
    else
        null;
    self.tablet_global.proximity(
        device_id,
        info,
        time,
        focus,
        in_proximity,
        self.routeTabletAxes(axes),
    ) catch self.terminate();
}

fn nativeTabletToolAxis(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    tool_id: NativeInput.TabletToolId,
    time: u32,
    axes: NativeInput.TabletToolAxes,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.idle_notify_global.notifyActivity();
    const routed = self.routeTabletAxes(axes);
    const focus = self.tabletAxesFocus(routed) catch return self.terminate();
    self.tablet_global.axis(device_id, tool_id, time, focus, routed) catch self.terminate();
}

fn nativeTabletToolTip(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    tool_id: NativeInput.TabletToolId,
    time: u32,
    axes: NativeInput.TabletToolAxes,
    down: bool,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.idle_notify_global.notifyActivity();
    const routed = self.routeTabletAxes(axes);
    const focus = self.tabletAxesFocus(routed) catch return self.terminate();
    self.tablet_global.tip(device_id, tool_id, time, focus, routed, down) catch self.terminate();
}

fn nativeTabletToolButton(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    tool_id: NativeInput.TabletToolId,
    time: u32,
    axes: NativeInput.TabletToolAxes,
    button: u32,
    pressed: bool,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) return;
    self.idle_notify_global.notifyActivity();
    const routed = self.routeTabletAxes(axes);
    const focus = self.tabletAxesFocus(routed) catch return self.terminate();
    self.tablet_global.button(
        device_id,
        tool_id,
        time,
        focus,
        routed,
        button,
        pressed,
    ) catch self.terminate();
}

fn nativeTabletPadButton(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, button: u32, pressed: bool, group: u32, mode: u32) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
    self.tablet_global.padButton(device_id, time, button, pressed, group, mode) catch self.terminate();
}

fn nativeTabletPadRing(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, ring: u32, position: f64, finger: bool, group: u32, mode: u32) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
    self.tablet_global.padRing(device_id, time, ring, position, finger, group, mode) catch self.terminate();
}

fn nativeTabletPadStrip(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, strip: u32, position: f64, finger: bool, group: u32, mode: u32) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
    self.tablet_global.padStrip(device_id, time, strip, position, finger, group, mode) catch self.terminate();
}

fn nativeTabletPadDial(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, dial: u32, value120: i32, group: u32, mode: u32) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.notifyActivity();
    self.tablet_global.padDial(device_id, time, dial, value120, group, mode) catch self.terminate();
}

fn cursorRepaint(context: *anyopaque) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (self.terminating) return;
    self.scheduleRepaint(0);
}

fn tabletSurfaceCoordinates(
    context: *anyopaque,
    surface: *CompositorGlobal.Surface,
    x: f64,
    y: f64,
) ?TabletGlobal.Point {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    const local = self.surfaceLocal(surface, x, y) orelse return null;
    return .{ .x = local.x, .y = local.y };
}

fn readIconBuffer(_: *anyopaque, fd: i32, offset: u64, destination: []u8) !void {
    var completed: usize = 0;
    while (completed < destination.len) {
        const result = linux.pread(
            fd,
            destination[completed..].ptr,
            destination.len - completed,
            @intCast(offset + completed),
        );
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.UnexpectedEndOfFile;
                completed += result;
            },
            .INTR => continue,
            else => return error.IconBufferReadFailed,
        }
    }
}

fn repaintTimer(_: *anyopaque, _: *EventLoop, _: u64) !void {}

fn idleNotifyTimer(context: *anyopaque, _: *EventLoop, _: u64) !void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.idle_notify_global.handleTimer();
}

fn idleNotifyNow(context: *anyopaque) i96 {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    return std.Io.Clock.awake.now(self.io).nanoseconds;
}

fn scheduleIdleNotify(context: *anyopaque, delay_milliseconds: ?u64) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (self.terminating) return;
    if (delay_milliseconds) |delay| {
        self.idle_notify_timer.arm(delay, 0) catch self.terminate();
    } else {
        self.idle_notify_timer.disarm();
    }
}

fn scheduleRepaint(self: *NativeServer, delay_milliseconds: u64) void {
    self.repaint_needed = true;
    self.repaint_timer.arm(@max(delay_milliseconds, 1), 0) catch self.terminate();
}

fn screencopyConstraints(context: *anyopaque) ?render.Size {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (self.terminating) return null;
    return switch (self.output) {
        .headless => self.output.modeSize(),
        .drm => |output| if (output != null) self.output.modeSize() else null,
    };
}

fn scheduleScreencopy(context: *anyopaque, wait_for_damage: bool) bool {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (screencopyConstraints(self) == null) return false;
    if (!wait_for_damage) self.scheduleRepaint(0);
    return true;
}

fn captureScreencopy(
    context: *anyopaque,
    commands: []const render.Command,
    scale: render.Scale,
    destination: render.PixelBuffer,
) !?std.posix.fd_t {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    try self.renderer.beginFrame(
        .{ .pixels = destination },
        scale,
        .{},
        null,
        self.output.colorDescription(),
    );
    var active = true;
    errdefer if (active) self.renderer.cancelFrame();
    try self.renderer.append(commands);
    active = false;
    return (try self.renderer.finishFrameReadback()).sync_file_fd;
}

fn completeScreencopy(context: *anyopaque, staging: render.PixelBuffer) bool {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.renderer.completeFrameReadback(staging, staging) catch return false;
    return true;
}

fn endTurn(context: *anyopaque, _: *EventLoop) !void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    try self.transport.flush();
}

fn refreshSeatCapabilities(self: *NativeServer) !void {
    var capabilities: u32 = 0;
    if (self.pointer_available) capabilities |= SeatGlobal.Capability.pointer;
    if (self.keyboard_available) capabilities |= SeatGlobal.Capability.keyboard;
    if (self.touch_available) capabilities |= SeatGlobal.Capability.touch;
    try self.seat_global.setPhysicalCapabilities(capabilities);
}

fn refreshKeyboardCapability(self: *NativeServer, seat: *SeatGlobal) !void {
    // Transient keyboard focus is assigned only by an explicit press from the
    // same seat. SeatGlobal clears it when the capability disappears.
    if (seat != &self.seat_global) return;
    if (seat.hasCapability(SeatGlobal.Capability.keyboard)) {
        try self.refreshKeyboardFocus(null);
        return;
    }
    self.xdg_shell.setActivatedSurface(null);
    try self.data_device_global.setKeyboardFocus(null);
    try self.primary_selection_global.setKeyboardFocus(null);
    self.last_keyboard_serial = 0;
}

fn refreshPointerCapability(self: *NativeServer, seat: *SeatGlobal) !void {
    if (!self.inputRoutingAvailable()) return;
    if (!seat.hasCapability(SeatGlobal.Capability.pointer)) return;
    const moved = try self.refreshPointerFocus(seat, 0);
    if (moved) try seat.pointerFrame();
}

fn pendingAxis(self: *NativeServer, axis: NativeInput.Axis) ?*PendingAxis {
    return switch (axis) {
        .vertical_scroll => &self.pointer_axes[0],
        .horizontal_scroll => &self.pointer_axes[1],
        else => null,
    };
}

fn flushPointerFrame(self: *NativeServer) !void {
    var source = self.pointer_axis_source;
    for (&self.pointer_axes, 0..) |*pending, index| {
        if (!pending.active) continue;
        try self.seat_global.pointerAxisFrame(.{
            .time_milliseconds = pending.time_milliseconds,
            .axis = @intCast(index),
            .value = pending.value,
            .source = source,
            .stopped = pending.stopped,
            .discrete = pending.discrete,
            .value120 = pending.value120,
        });
        source = null;
    }
    try self.seat_global.pointerFrame();
    self.pointer_axes = .{ .{}, .{} };
    self.pointer_axis_source = null;
}

const VirtualPointerBounds = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

fn virtualPointerBounds(
    self: *const NativeServer,
    mapped_output: ?*OutputGlobal,
) VirtualPointerBounds {
    const output = mapped_output orelse &self.output_global;
    const position = output.logicalPosition();
    const size = output.logicalSize();
    return .{
        .x = @floatFromInt(position.x),
        .y = @floatFromInt(position.y),
        .width = @floatFromInt(size.width),
        .height = @floatFromInt(size.height),
    };
}

fn virtualPointerEvent(
    context: *anyopaque,
    seat: *SeatGlobal,
    mapped_output: ?*OutputGlobal,
    source: u64,
    event: VirtualPointerGlobal.Event,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    if (!self.inputRoutingAvailable()) {
        switch (event) {
            .button => |button| if (button.state == @intFromEnum(
                NativeInput.ButtonState.released,
            )) {
                _ = self.removeRoutedButton(
                    seat,
                    .{ .virtual = source },
                    button.button,
                );
            },
            else => {},
        }
        return;
    }
    switch (event) {
        .motion => |motion| {
            self.idle_notify_global.notifyActivity();
            // Relative-pointer-v1 remains default-seat-only. A transient
            // virtual pointer must not leak motion to the default focus.
            if (seat == &self.seat_global) self.relative_pointer_global.motion(
                @as(u64, motion.time) * std.time.us_per_ms,
                motion.dx,
                motion.dy,
                motion.dx,
                motion.dy,
            ) catch return self.terminate();
            const bounds = self.virtualPointerBounds(mapped_output);
            const x = clampVirtualPointerCoordinate(
                self.pointerLogicalX(seat) + motion.dx,
                bounds.x,
                bounds.width,
            );
            const y = clampVirtualPointerCoordinate(
                self.pointerLogicalY(seat) + motion.dy,
                bounds.y,
                bounds.height,
            );
            self.moveVirtualPointer(seat, motion.time, x, y) catch self.terminate();
        },
        .motion_absolute => |motion| {
            self.idle_notify_global.notifyActivity();
            if (motion.x_extent == 0 or motion.y_extent == 0) return;
            const bounds = self.virtualPointerBounds(mapped_output);
            const x = normalizedVirtualPointerCoordinate(
                motion.x,
                motion.x_extent,
                bounds.x,
                bounds.width,
            );
            const y = normalizedVirtualPointerCoordinate(
                motion.y,
                motion.y_extent,
                bounds.y,
                bounds.height,
            );
            self.moveVirtualPointer(seat, motion.time, x, y) catch self.terminate();
        },
        .button => |button| {
            self.idle_notify_global.notifyActivity();
            self.routePointerButtonFromSource(
                seat,
                .{ .virtual = source },
                button.time,
                button.button,
                @enumFromInt(button.state),
            ) catch self.terminate();
        },
        .axis => |axis| {
            self.idle_notify_global.notifyActivity();
            seat.pointerAxisFrame(.{
                .time_milliseconds = axis.time,
                .axis = axis.axis,
                .value = axis.value,
            }) catch self.terminate();
        },
        .frame => seat.pointerFrame() catch self.terminate(),
        .axis_source => |axis_source| {
            self.idle_notify_global.notifyActivity();
            seat.pointerAxisFrame(.{
                .time_milliseconds = 0,
                .axis = 0,
                .source = axis_source,
            }) catch self.terminate();
        },
        .axis_stop => |axis| {
            self.idle_notify_global.notifyActivity();
            seat.pointerAxisFrame(.{
                .time_milliseconds = axis.time,
                .axis = axis.axis,
                .stopped = true,
            }) catch self.terminate();
        },
        .axis_discrete => |axis| {
            self.idle_notify_global.notifyActivity();
            seat.pointerAxisFrame(.{
                .time_milliseconds = axis.time,
                .axis = axis.axis,
                .value = axis.value,
                .discrete = axis.discrete,
                .value120 = axis.discrete *| 120,
            }) catch self.terminate();
        },
    }
}

fn moveVirtualPointer(
    self: *NativeServer,
    seat: *SeatGlobal,
    time: u32,
    x: f64,
    y: f64,
) !void {
    if (seat == &self.seat_global) {
        self.pointer_physical_x = logicalToPhysicalScale(x, self.output.scale());
        self.pointer_physical_y = logicalToPhysicalScale(y, self.output.scale());
        if (self.native_input_initialized)
            self.native_input.setPointerPosition(self.pointer_physical_x, self.pointer_physical_y);
        self.syncPointerCursorPosition();
    } else {
        seat.setLogicalPointerPosition(x, y);
    }
    _ = try self.refreshPointerFocus(seat, time);
}

fn clampVirtualPointerCoordinate(value: f64, origin: f64, dimension: f64) f64 {
    std.debug.assert(dimension >= 1);
    return std.math.clamp(value, origin, origin + dimension - 1);
}

fn normalizedVirtualPointerCoordinate(
    value: u32,
    extent: u32,
    origin: f64,
    dimension: f64,
) f64 {
    std.debug.assert(extent > 0 and dimension >= 1);
    const normalized = @as(f64, @floatFromInt(@min(value, extent))) /
        @as(f64, @floatFromInt(extent));
    return origin + normalized * (dimension - 1);
}

fn routeKeyboardKey(
    self: *NativeServer,
    device_id: NativeInput.DeviceId,
    time: u32,
    key: u32,
    state: NativeInput.KeyState,
) !void {
    switch (state) {
        .pressed => {
            for (self.routed_keys.items) |routed|
                if (routed.device_id == device_id and routed.key == key) return;
            const already_held = self.keyHeld(key);
            try self.routed_keys.append(self.allocator, .{ .device_id = device_id, .key = key });
            if (already_held) return;
        },
        .released => {
            var found: ?usize = null;
            for (self.routed_keys.items, 0..) |routed, index| {
                if (routed.device_id == device_id and routed.key == key) {
                    found = index;
                    break;
                }
            }
            const unattributed = self.removeUnattributedKey(key);
            if (found) |index| {
                _ = self.routed_keys.orderedRemove(index);
            } else if (!unattributed) return;
            if (self.keyHeld(key)) return;
        },
        else => return,
    }
    if (try self.seat_global.keyboardKey(time, key, @intFromEnum(state))) |serial|
        self.last_keyboard_serial = serial;
}

fn releaseDeviceKeys(self: *NativeServer, device_id: NativeInput.DeviceId) !void {
    var index: usize = 0;
    while (index < self.routed_keys.items.len) {
        const routed = self.routed_keys.items[index];
        if (routed.device_id != device_id) {
            index += 1;
            continue;
        }
        _ = self.routed_keys.orderedRemove(index);
        if (self.keyHeld(routed.key)) continue;
        if (try self.seat_global.keyboardKey(
            0,
            routed.key,
            @intFromEnum(NativeInput.KeyState.released),
        )) |serial| self.last_keyboard_serial = serial;
    }
}

fn keyHeld(self: *const NativeServer, key: u32) bool {
    if (std.mem.indexOfScalar(u32, self.unattributed_keys.items, key) != null) return true;
    for (self.routed_keys.items) |routed| if (routed.key == key) return true;
    return false;
}

fn removeUnattributedKey(self: *NativeServer, key: u32) bool {
    const index = std.mem.indexOfScalar(u32, self.unattributed_keys.items, key) orelse return false;
    _ = self.unattributed_keys.orderedRemove(index);
    return true;
}

fn refreshKeyboardFocus(
    self: *NativeServer,
    preferred: ?*CompositorGlobal.Surface,
) !void {
    if (!self.seat_global.hasCapability(SeatGlobal.Capability.keyboard)) return;
    const exclusive = self.layer_shell.exclusiveKeyboardSurface();
    const restore = if (exclusive == null and self.exclusive_focus_active)
        self.exclusive_focus_restore
    else
        null;
    defer if (restore) |surface| surface.unreference();
    if (exclusive != null and !self.exclusive_focus_active) {
        self.exclusive_focus_active = true;
        if (self.seat_global.keyboardFocus()) |surface| {
            if (self.surfaceActive(surface) and self.layer_shell.rootClass(surface) == .desktop) {
                try surface.reference();
                self.exclusive_focus_restore = surface;
            }
        }
    } else if (exclusive == null and self.exclusive_focus_active) {
        self.exclusive_focus_active = false;
        self.exclusive_focus_restore = null;
    }
    const target = exclusive orelse if (restore) |surface|
        if (self.surfaceActive(surface) and self.layer_shell.rootClass(surface) == .desktop)
            surface
        else
            try self.topmostDesktopRoot()
    else if (preferred) |surface|
        if (self.surfaceActive(surface) and self.layer_shell.rootClass(surface) == .desktop)
            surface
        else
            try self.topmostDesktopRoot()
    else
        try self.topmostDesktopRoot();
    if (self.seat_global.keyboardFocus() == target) {
        self.xdg_shell.setActivatedSurface(target);
        return;
    }
    if (target == null) {
        _ = try self.seat_global.keyboardLeave();
        self.xdg_shell.setActivatedSurface(null);
        try self.data_device_global.setKeyboardFocus(null);
        try self.primary_selection_global.setKeyboardFocus(null);
        self.last_keyboard_serial = 0;
        return;
    }
    self.keyboard_enter_keys.clearRetainingCapacity();
    for (self.unattributed_keys.items) |key|
        if (std.mem.indexOfScalar(u32, self.keyboard_enter_keys.items, key) == null)
            try self.keyboard_enter_keys.append(self.allocator, key);
    for (self.routed_keys.items) |routed|
        if (std.mem.indexOfScalar(u32, self.keyboard_enter_keys.items, routed.key) == null)
            try self.keyboard_enter_keys.append(self.allocator, routed.key);
    const serial = try self.seat_global.keyboardEnter(
        target.?,
        self.keyboard_enter_keys.items,
    );
    self.last_keyboard_serial = serial;
    try self.seat_global.sendCurrentKeyboardModifiers(serial);
    self.xdg_shell.setActivatedSurface(target);
    try self.data_device_global.setKeyboardFocus(target.?.client);
    try self.primary_selection_global.setKeyboardFocus(target.?.client);
}

fn reenterKeyboardFocus(self: *NativeServer) !void {
    const current = self.seat_global.keyboardFocus() orelse
        return self.refreshKeyboardFocus(null);
    try current.reference();
    defer current.unreference();
    _ = try self.seat_global.keyboardLeave();
    self.last_keyboard_serial = 0;
    try self.refreshKeyboardFocus(current);
}

fn refreshTransientKeyboardFocus(
    self: *NativeServer,
    seat: *SeatGlobal,
    preferred: ?*CompositorGlobal.Surface,
) !void {
    std.debug.assert(seat != &self.seat_global);
    if (!seat.hasCapability(SeatGlobal.Capability.keyboard)) return;
    const target = if (preferred) |surface|
        if (self.surfaceActive(surface)) surface else null
    else
        null;
    if (seat.keyboardFocus() == target) return;
    if (target == null) {
        _ = try seat.keyboardLeave();
        return;
    }
    const serial = try seat.keyboardEnter(target.?, &.{});
    try seat.sendCurrentKeyboardModifiers(serial);
}

fn routePointerButton(
    self: *NativeServer,
    device_id: NativeInput.DeviceId,
    time: u32,
    button: u32,
    state: NativeInput.ButtonState,
) !void {
    try self.routePointerButtonFromSource(
        &self.seat_global,
        .{ .physical = device_id },
        time,
        button,
        state,
    );
}

fn routePointerButtonFromSource(
    self: *NativeServer,
    seat: *SeatGlobal,
    source: PointerSource,
    time: u32,
    button: u32,
    state: NativeInput.ButtonState,
) !void {
    if (!self.inputRoutingAvailable()) return;
    switch (state) {
        .pressed => {
            _ = try self.refreshPointerFocus(seat, time);
            for (self.routed_buttons.items) |routed|
                if (routed.seat == seat and
                    std.meta.eql(routed.source, source) and
                    routed.button == button) return;
            const already_held = self.buttonHeld(seat, button);
            try self.routed_buttons.append(self.allocator, .{
                .seat = seat,
                .source = source,
                .button = button,
            });
            if (already_held) return;
            if (try self.hitTestPointer(seat)) |hit| {
                if (seat == &self.seat_global) {
                    try self.refreshKeyboardFocus(hit.root);
                } else {
                    try self.refreshTransientKeyboardFocus(seat, hit.root);
                }
            }
        },
        .released => {
            if (!self.removeRoutedButton(seat, source, button)) return;
            if (self.buttonHeld(seat, button)) return;
        },
        else => return,
    }
    _ = try seat.pointerButton(time, button, @intFromEnum(state));
    if (state == .released and !self.seatHasRoutedButtons(seat))
        _ = try self.refreshPointerFocus(seat, time);
}

fn releaseDeviceButtons(self: *NativeServer, device_id: NativeInput.DeviceId) !void {
    var sent = false;
    var index: usize = 0;
    while (index < self.routed_buttons.items.len) {
        const routed = self.routed_buttons.items[index];
        if (routed.seat != &self.seat_global or
            routed.source != .physical or
            routed.source.physical != device_id)
        {
            index += 1;
            continue;
        }
        _ = self.routed_buttons.orderedRemove(index);
        if (self.buttonHeld(&self.seat_global, routed.button)) continue;
        _ = try self.seat_global.pointerButton(
            0,
            routed.button,
            @intFromEnum(NativeInput.ButtonState.released),
        );
        sent = true;
    }
    const moved = if (!self.seatHasRoutedButtons(&self.seat_global))
        try self.refreshPointerFocus(&self.seat_global, 0)
    else
        false;
    if (sent or moved) try self.seat_global.pointerFrame();
}

fn releasePhysicalButtons(self: *NativeServer) !void {
    var sent = false;
    var index: usize = 0;
    while (index < self.routed_buttons.items.len) {
        const routed = self.routed_buttons.items[index];
        if (routed.seat != &self.seat_global or routed.source != .physical) {
            index += 1;
            continue;
        }
        _ = self.routed_buttons.orderedRemove(index);
        if (self.buttonHeld(&self.seat_global, routed.button)) continue;
        _ = try self.seat_global.pointerButton(
            0,
            routed.button,
            @intFromEnum(NativeInput.ButtonState.released),
        );
        sent = true;
    }
    const moved = if (!self.seatHasRoutedButtons(&self.seat_global))
        try self.refreshPointerFocus(&self.seat_global, 0)
    else
        false;
    if (sent or moved) try self.seat_global.pointerFrame();
}

fn buttonHeld(self: *const NativeServer, seat: *const SeatGlobal, button: u32) bool {
    for (self.routed_buttons.items) |routed|
        if (routed.seat == seat and routed.button == button) return true;
    return false;
}

fn removeRoutedButton(
    self: *NativeServer,
    seat: *const SeatGlobal,
    source: PointerSource,
    button: u32,
) bool {
    for (self.routed_buttons.items, 0..) |routed, index| {
        if (routed.seat != seat or
            !std.meta.eql(routed.source, source) or
            routed.button != button) continue;
        _ = self.routed_buttons.orderedRemove(index);
        return true;
    }
    return false;
}

fn seatHasRoutedButtons(self: *const NativeServer, seat: *const SeatGlobal) bool {
    for (self.routed_buttons.items) |routed| if (routed.seat == seat) return true;
    return false;
}

fn removeRoutedButtonsForSeat(self: *NativeServer, seat: *const SeatGlobal) void {
    var index: usize = 0;
    while (index < self.routed_buttons.items.len) {
        if (self.routed_buttons.items[index].seat != seat) {
            index += 1;
            continue;
        }
        _ = self.routed_buttons.orderedRemove(index);
    }
}

fn refreshPointerFocus(self: *NativeServer, seat: *SeatGlobal, time: u32) !bool {
    if (!self.inputRoutingAvailable()) return false;
    if (!seat.hasCapability(SeatGlobal.Capability.pointer)) return false;
    if (self.seatHasRoutedButtons(seat)) {
        if (seat.pointerFocus()) |surface| {
            if (self.surfaceLocal(
                surface,
                self.pointerLogicalX(seat),
                self.pointerLogicalY(seat),
            )) |local|
                return seat.pointerMotion(
                    time,
                    fixedFromDouble(local.x),
                    fixedFromDouble(local.y),
                );
        }
        self.removeRoutedButtonsForSeat(seat);
    }
    const hit = try self.hitTestPointer(seat);
    if (hit) |target| {
        const x = fixedFromDouble(target.local_x);
        const y = fixedFromDouble(target.local_y);
        if (seat.pointerFocus() == target.surface) {
            return seat.pointerMotion(time, x, y);
        } else {
            _ = try seat.pointerEnter(target.surface, x, y);
            return false;
        }
    } else {
        _ = try seat.pointerLeave();
        return false;
    }
}

fn routeTouchDown(
    self: *NativeServer,
    device_id: NativeInput.DeviceId,
    time: u32,
    native_id: i32,
    physical_x: f64,
    physical_y: f64,
) !void {
    if (!self.inputRoutingAvailable()) return;
    const x = self.physicalToLogical(physical_x);
    const y = self.physicalToLogical(physical_y);
    const hit = (try self.hitTest(x, y)) orelse return;
    if (self.touch_routes.items.len != 0 and self.touch_routes.items[0].surface != hit.surface)
        try self.cancelTouches();
    try self.touch_routes.ensureUnusedCapacity(self.allocator, 1);
    try hit.surface.reference();
    errdefer hit.surface.unreference();
    const protocol_id = self.allocateTouchId();
    _ = try self.seat_global.touchDown(
        hit.surface,
        time,
        protocol_id,
        fixedFromDouble(hit.local_x),
        fixedFromDouble(hit.local_y),
    );
    self.touch_routes.appendAssumeCapacity(.{
        .device_id = device_id,
        .native_id = native_id,
        .protocol_id = protocol_id,
        .surface = hit.surface,
    });
}

fn routeTouchUp(
    self: *NativeServer,
    device_id: NativeInput.DeviceId,
    time: u32,
    native_id: i32,
) !void {
    const index = self.touchRouteIndex(device_id, native_id) orelse return;
    const route = self.touch_routes.orderedRemove(index);
    defer route.surface.unreference();
    _ = try self.seat_global.touchUp(time, route.protocol_id);
    if (self.touch_routes.items.len == 0) self.seat_global.touchFinish();
}

fn routeTouchMotion(
    self: *NativeServer,
    device_id: NativeInput.DeviceId,
    time: u32,
    native_id: i32,
    physical_x: f64,
    physical_y: f64,
) !void {
    if (!self.inputRoutingAvailable()) return;
    const index = self.touchRouteIndex(device_id, native_id) orelse return;
    const route = self.touch_routes.items[index];
    const local = self.surfaceLocal(
        route.surface,
        self.physicalToLogical(physical_x),
        self.physicalToLogical(physical_y),
    ) orelse return self.cancelTouches();
    try self.seat_global.touchMotion(
        time,
        route.protocol_id,
        fixedFromDouble(local.x),
        fixedFromDouble(local.y),
    );
}

fn cancelTouches(self: *NativeServer) !void {
    try self.seat_global.touchCancel();
    for (self.touch_routes.items) |route| route.surface.unreference();
    self.touch_routes.clearRetainingCapacity();
}

fn touchRouteIndex(
    self: *const NativeServer,
    device_id: NativeInput.DeviceId,
    native_id: i32,
) ?usize {
    for (self.touch_routes.items, 0..) |route, index|
        if (route.device_id == device_id and route.native_id == native_id) return index;
    return null;
}

fn allocateTouchId(self: *NativeServer) i32 {
    const result: i32 = @intCast(self.next_touch_id);
    self.next_touch_id = if (self.next_touch_id == std.math.maxInt(i32))
        1
    else
        self.next_touch_id + 1;
    return result;
}

fn hitTestPointer(self: *NativeServer, seat: *const SeatGlobal) !?Hit {
    if (!self.inputRoutingAvailable()) return null;
    return self.hitTest(self.pointerLogicalX(seat), self.pointerLogicalY(seat));
}

fn hitTest(self: *NativeServer, x: f64, y: f64) !?Hit {
    try self.collectInputPaintEntries();
    var index = self.input_paint_entries.items.len;
    while (index > 0) {
        index -= 1;
        const entry = self.input_paint_entries.items[index];
        const state = self.findState(entry.surface) orelse continue;
        if (!state.surface.resource_alive) continue;
        const size = xdgSurfaceSize(self, state.surface) orelse continue;
        const buffer_x = entry.x +| state.x;
        const buffer_y = entry.y +| state.y;
        if (x < @as(f64, @floatFromInt(buffer_x)) or
            y < @as(f64, @floatFromInt(buffer_y)) or
            x >= @as(f64, @floatFromInt(buffer_x)) + @as(f64, @floatFromInt(size.width)) or
            y >= @as(f64, @floatFromInt(buffer_y)) + @as(f64, @floatFromInt(size.height)))
        {
            continue;
        }
        const local_x = x - @as(f64, @floatFromInt(entry.x));
        const local_y = y - @as(f64, @floatFromInt(entry.y));
        if (!state.input_region.accepts(local_x, local_y)) continue;
        const node = self.surface_tree.find(state.surface) orelse continue;
        return .{
            .surface = state.surface,
            .root = SurfaceTree.root(node).surface,
            // Attach offsets move buffer bounds, not the wl_surface coordinate origin.
            .local_x = local_x,
            .local_y = local_y,
        };
    }
    return null;
}

fn topmostDesktopRoot(self: *NativeServer) !?*CompositorGlobal.Surface {
    try self.collectInputPaintEntries();
    var index = self.input_paint_entries.items.len;
    while (index > 0) {
        index -= 1;
        const surface = self.input_paint_entries.items[index].surface;
        if (!surface.resource_alive or self.findState(surface) == null) continue;
        const node = self.surface_tree.find(surface) orelse continue;
        const root = SurfaceTree.root(node).surface;
        if (self.layer_shell.rootClass(root) == .desktop) return root;
    }
    return null;
}

fn activateToplevel(
    self: *NativeServer,
    root: *CompositorGlobal.Surface,
) !void {
    std.debug.assert(self.surfaceActive(root));
    std.debug.assert(self.xdg_shell.isToplevelSurface(root));
    if (self.raiseRoot(root)) self.repaint_needed = true;
    try self.refreshKeyboardFocus(root);
}

fn raiseRoot(self: *NativeServer, root: *CompositorGlobal.Surface) bool {
    if (self.layer_shell.rootClass(root) != .desktop) return false;
    var root_index: ?usize = null;
    var topmost_root_index: ?usize = null;
    for (self.surfaces.items, 0..) |state, index| {
        const node = self.surface_tree.find(state.surface) orelse continue;
        if (node.parent != null or self.isCursorSurface(state.surface) or
            self.layer_shell.rootClass(state.surface) != .desktop) continue;
        topmost_root_index = index;
        if (state.surface == root) root_index = index;
    }
    const index = root_index orelse return false;
    if (topmost_root_index == index) return false;
    const state = self.surfaces.orderedRemove(index);
    self.surfaces.appendAssumeCapacity(state);
    return true;
}

fn collectInputPaintEntries(self: *NativeServer) !void {
    self.input_paint_entries.clearRetainingCapacity();
    try self.collectRootPaintEntries(&self.input_paint_entries);
}

fn collectRootPaintEntries(self: *NativeServer, entries: *std.ArrayList(SurfaceTree.PaintEntry)) !void {
    inline for (std.meta.tags(LayerShell.RootClass)) |class| {
        for (self.surfaces.items) |state| {
            const node = self.surface_tree.find(state.surface) orelse continue;
            if (node.parent == null and !self.isCursorSurface(state.surface) and
                self.layer_shell.rootClass(state.surface) == class)
                try self.surface_tree.paint(node, entries);
        }
    }
}

fn surfaceLocal(
    self: *const NativeServer,
    surface: *const CompositorGlobal.Surface,
    x: f64,
    y: f64,
) ?struct { x: f64, y: f64 } {
    if (!surface.resource_alive or self.findState(surface) == null) return null;
    const node = self.surface_tree.find(surface) orelse return null;
    if (!node.current_active) return null;
    const position = SurfaceTree.globalPosition(node);
    return .{
        .x = x - @as(f64, @floatFromInt(position.x)),
        .y = y - @as(f64, @floatFromInt(position.y)),
    };
}

fn surfaceActive(self: *const NativeServer, surface: *const CompositorGlobal.Surface) bool {
    if (!surface.resource_alive or self.findState(surface) == null) return false;
    const node = self.surface_tree.find(surface) orelse return false;
    return node.current_active;
}

fn refreshIdleInhibition(self: *NativeServer) void {
    self.idle_notify_global.setInhibited(
        self.idle_inhibit_global.hasVisibleInhibitor(
            self,
            idleInhibitorSurfaceVisible,
        ),
    );
}

fn idleInhibitorSurfaceVisible(
    context: *anyopaque,
    surface: *const CompositorGlobal.Surface,
) bool {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    // A synchronized child may participate in the hierarchy without its own
    // buffer. Match scene painting: require an image and every active ancestor.
    const state = self.findState(surface) orelse return false;
    if (state.snapshot == null and state.dmabuf == null) return false;
    const node = self.surface_tree.find(surface) orelse return false;
    var current = node;
    while (true) {
        if (!current.current_active) return false;
        current = current.parent orelse break;
    }
    return current.surface.resource_alive and !self.isCursorSurface(current.surface);
}

fn pointerLogicalX(self: *const NativeServer, seat: *const SeatGlobal) f64 {
    if (seat == &self.seat_global)
        return self.physicalToLogical(self.pointer_physical_x);
    return seat.logicalPointerPosition().x;
}

fn pointerLogicalY(self: *const NativeServer, seat: *const SeatGlobal) f64 {
    if (seat == &self.seat_global)
        return self.physicalToLogical(self.pointer_physical_y);
    return seat.logicalPointerPosition().y;
}

fn syncPointerCursorPosition(self: *NativeServer) void {
    self.pointer_cursor.setPosition(
        self.pointerLogicalX(&self.seat_global),
        self.pointerLogicalY(&self.seat_global),
    );
}

fn isCursorSurface(
    self: *const NativeServer,
    surface: *const CompositorGlobal.Surface,
) bool {
    return self.pointer_cursor.isCursorSurface(surface) or
        self.tablet_global.isCursorSurface(surface);
}

fn physicalToLogical(self: *const NativeServer, value: f64) f64 {
    return physicalToLogicalScale(value, self.output.scale());
}

fn routeTabletAxes(
    self: *const NativeServer,
    axes: NativeInput.TabletToolAxes,
) NativeInput.TabletToolAxes {
    var routed = axes;
    if (axes.position) |position| routed.position = .{
        .x = self.physicalToLogical(position.x),
        .y = self.physicalToLogical(position.y),
    };
    return routed;
}

fn tabletAxesFocus(
    self: *NativeServer,
    axes: NativeInput.TabletToolAxes,
) !?TabletGlobal.Focus {
    const position = axes.position orelse return null;
    return self.tabletFocus(position.x, position.y);
}

fn tabletFocus(self: *NativeServer, x: f64, y: f64) !?TabletGlobal.Focus {
    if (!self.inputRoutingAvailable()) return null;
    const hit = (try self.hitTest(x, y)) orelse return null;
    return .{ .surface = hit.surface, .x = hit.local_x, .y = hit.local_y };
}

fn physicalToLogicalScale(value: f64, scale: render.Scale) f64 {
    std.debug.assert(scale.numerator > 0);
    return value * render.Scale.denominator / @as(f64, @floatFromInt(scale.numerator));
}

fn logicalToPhysicalScale(value: f64, scale: render.Scale) f64 {
    std.debug.assert(scale.numerator > 0);
    return value * @as(f64, @floatFromInt(scale.numerator)) / render.Scale.denominator;
}

fn clampPointerCoordinate(value: f64, dimension: u32) f64 {
    std.debug.assert(dimension > 0);
    return std.math.clamp(value, 0, @as(f64, @floatFromInt(dimension - 1)));
}

fn fixedFromDouble(value: f64) i32 {
    const minimum = @as(f64, @floatFromInt(std.math.minInt(i32))) / 256.0;
    const maximum = @as(f64, @floatFromInt(std.math.maxInt(i32))) / 256.0;
    return @intFromFloat(std.math.clamp(value, minimum, maximum) * 256.0);
}

fn inputTime(self: *const NativeServer) u32 {
    const now = std.Io.Clock.awake.now(self.io).toMilliseconds();
    return @truncate(@as(u64, @intCast(@max(now, 0))));
}

fn refreshInputFocus(self: *NativeServer, time: u32) !void {
    if (self.seat_global.hasCapability(SeatGlobal.Capability.pointer) and
        try self.refreshPointerFocus(&self.seat_global, time))
        try self.seat_global.pointerFrame();
    if (self.seat_global.hasCapability(SeatGlobal.Capability.keyboard))
        try self.refreshKeyboardFocus(null);
    var transient_seats = self.transient_seat_global.seatIterator();
    while (transient_seats.next()) |seat| {
        if (seat.hasCapability(SeatGlobal.Capability.pointer) and
            try self.refreshPointerFocus(seat, time))
            try seat.pointerFrame();
        if (seat.keyboardFocus()) |focus| {
            if (!self.surfaceActive(focus))
                try self.refreshTransientKeyboardFocus(seat, null);
        }
    }
    for (self.touch_routes.items) |route| {
        if (!self.surfaceActive(route.surface)) {
            try self.cancelTouches();
            break;
        }
    }
}

fn deinitInputState(self: *NativeServer) void {
    self.active_gesture = null;
    for (self.touch_routes.items) |route| route.surface.unreference();
    self.touch_routes.deinit(self.allocator);
    self.keyboard_enter_keys.deinit(self.allocator);
    self.unattributed_keys.deinit(self.allocator);
    self.routed_buttons.deinit(self.allocator);
    self.routed_keys.deinit(self.allocator);
    self.input_paint_entries.deinit(self.allocator);
}

fn intakeTransactions(self: *NativeServer) !void {
    while (self.compositor_global.popTransaction()) |transaction| {
        const pending = self.allocator.create(PendingTransaction) catch {
            var owned = transaction;
            owned.releaseBuffers();
            owned.deinit();
            return error.OutOfMemory;
        };
        const entries = self.allocator.alloc(PendingEntry, transaction.entries.len) catch {
            self.allocator.destroy(pending);
            var owned = transaction;
            owned.releaseBuffers();
            owned.deinit();
            return error.OutOfMemory;
        };
        for (entries) |*entry| entry.* = .{};
        pending.* = .{ .transaction = transaction, .entries = entries };
        self.pending.append(self.allocator, pending) catch {
            self.allocator.free(entries);
            pending.transaction.releaseBuffers();
            pending.transaction.deinit();
            self.allocator.destroy(pending);
            return error.OutOfMemory;
        };
    }
}

fn isRootHead(self: *const NativeServer, index: usize) bool {
    const root = self.retainedRoot(self.pending.items[index].transaction.root);
    for (self.pending.items[0..index]) |earlier|
        if (self.retainedRoot(earlier.transaction.root) == root) return false;
    return true;
}

fn retainedRoot(self: *const NativeServer, surface: *CompositorGlobal.Surface) *CompositorGlobal.Surface {
    const node = self.surface_tree.find(surface) orelse return surface;
    return SurfaceTree.root(node).surface;
}

fn prepareCommit(self: *NativeServer, commit: *CompositorGlobal.Commit, entry: *PendingEntry) !bool {
    if (try self.layer_shell.handleCommit(commit)) |result| {
        entry.layer_shell_commit = result.staged;
        entry.skip_application = result.disposition != .render;
        return commit.surface.client.state == .active;
    }
    const result = try self.xdg_shell.handleCommit(commit);
    entry.direct_update = result.direct_update;
    entry.skip_application = result.disposition == .configure_only;
    return commit.surface.client.state == .active;
}

fn isProtocolError(err: anyerror) bool {
    return err == error.ProtocolError or err == error.ProtocolErrorWithoutEvent;
}

fn applyEntry(
    self: *NativeServer,
    commit: *CompositorGlobal.Commit,
    pending_entry: *PendingEntry,
) !void {
    const state = self.findState(commit.surface) orelse unreachable;
    // Apply allocation-free while leaving the previous state owned by the
    // commit, whose transaction teardown will release it.
    std.mem.swap(Region, &state.opaque_region, &commit.opaque_region);
    std.mem.swap(
        CompositorGlobal.InputRegion,
        &state.input_region,
        &commit.input_region,
    );
    state.full_damage = state.full_damage or
        state.scale != commit.scale or
        !std.meta.eql(state.color_representation, commit.color_representation) or
        state.alpha_multiplier != commit.alpha_multiplier or
        state.transform != commit.transform or
        state.x != commit.offset_x or
        state.y != commit.offset_y or
        !std.meta.eql(state.viewport, commit.viewport);
    state.scale = commit.scale;
    state.content_type = commit.content_type;
    state.color_representation = commit.color_representation;
    state.alpha_multiplier = commit.alpha_multiplier;
    state.presentation_hint = commit.presentation_hint;
    state.transform = commit.transform;
    state.x = commit.offset_x;
    state.y = commit.offset_y;
    state.viewport = commit.viewport;
    switch (commit.attachment) {
        .buffer => |attachment| {
            if (attachment.buffer.content == .dmabuf) {
                const dmabuf = &attachment.buffer.content.dmabuf;
                std.debug.assert(pending_entry.dmabuf_reference_held);
                pending_entry.dmabuf_reference_held = false;
                if (state.snapshot) |*snapshot| snapshot.deinit();
                state.snapshot = null;
                if (state.dmabuf) |*old| old.deinit(
                    state.surface.client,
                    old.buffer != attachment.buffer or
                        !std.meta.eql(old.resource, attachment.resource),
                );
                state.dmabuf = .{
                    .buffer = attachment.buffer,
                    .resource = attachment.resource,
                    .source_cache = dmabuf.acquireSourceCache(),
                    .synchronization = commit.synchronization,
                };
                commit.synchronization = null;
                pending_entry.release_needed = false;
                try self.output_global.setSurfaceVisible(state.surface, true);
                return;
            }
            if (pending_entry.copy_failed) {
                if (state.snapshot) |*old| old.deinit();
                state.snapshot = null;
                if (state.dmabuf) |*dmabuf| dmabuf.deinit(state.surface.client, true);
                state.dmabuf = null;
                try self.output_global.setSurfaceVisible(state.surface, false);
                commit.releaseBuffer() catch {};
                pending_entry.release_needed = false;
                return;
            }
            const snapshot = pending_entry.snapshot orelse return error.MissingStagedSnapshot;
            pending_entry.snapshot = null;
            if (state.snapshot) |*old| old.deinit();
            state.snapshot = snapshot;
            if (state.dmabuf) |*dmabuf| dmabuf.deinit(state.surface.client, true);
            state.dmabuf = null;
            try self.output_global.setSurfaceVisible(state.surface, true);
            commit.releaseBuffer() catch {};
            pending_entry.release_needed = false;
        },
        .removed => {
            if (state.snapshot) |*snapshot| snapshot.deinit();
            state.snapshot = null;
            if (state.dmabuf) |*dmabuf| dmabuf.deinit(state.surface.client, true);
            state.dmabuf = null;
            try self.output_global.setSurfaceVisible(state.surface, false);
        },
        .unchanged => {
            // Geometry was validated for every entry before any state changed.
        },
    }
}

fn prepareApplication(self: *NativeServer, pending: *PendingTransaction) !void {
    for (pending.transaction.entries, pending.entries) |*commit, *entry| {
        if (entry.skip_application) continue;
        const state = try self.stateFor(commit.surface);
        const size: ?render.Size = switch (commit.attachment) {
            .buffer => |attachment| switch (attachment.buffer.content) {
                .dmabuf => |*dmabuf| size: {
                    try attachment.buffer.reference();
                    entry.dmabuf_reference_held = true;
                    break :size dmabuf.size;
                },
                .shm => if (entry.copy_failed)
                    null
                else
                    (entry.snapshot orelse return error.MissingStagedSnapshot).size,
                .single_pixel => (entry.snapshot orelse return error.MissingStagedSnapshot).size,
            },
            .removed => null,
            .unchanged => if (state.dmabuf) |dmabuf|
                dmabuf.buffer.content.dmabuf.size
            else if (state.snapshot) |*snapshot|
                snapshot.size
            else
                null,
        };
        if (size) |buffer_size| {
            _ = surface_geometry.calculate(
                buffer_size,
                commit.scale,
                @intCast(commit.transform),
                commit.viewport,
                false,
            ) catch |err| return self.viewporter_global.postGeometryError(state.surface, err);
        }
    }
}

fn armSyncWait(self: *NativeServer, entry: *PendingEntry, commit: *CompositorGlobal.Commit) !void {
    std.debug.assert(entry.handle == null and entry.event_fd < 0);
    const synchronization = commit.synchronization orelse
        return error.MissingSynchronization;
    const event_result = linux.eventfd(0, linux.EFD.CLOEXEC);
    if (std.posix.errno(event_result) != .SUCCESS) return error.SyncWaitFailed;
    entry.event_fd = @intCast(event_result);
    errdefer {
        _ = linux.close(entry.event_fd);
        entry.event_fd = -1;
    }
    if (!synchronization.acquire.armEventFd(entry.event_fd)) return error.SyncWaitFailed;
    entry.event_value = 0;
    entry.completed = false;
    entry.handle = try self.event_loop.ioLoop().queue(
        entry,
        syncWaitComplete,
        entry,
        prepareSyncWaitRead,
    );
}

fn prepareSyncWaitRead(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
    const entry: *PendingEntry = @ptrCast(@alignCast(context));
    sqe.prep_read(entry.event_fd, std.mem.asBytes(&entry.event_value), 0);
}

fn syncWaitComplete(
    context: *anyopaque,
    _: *IoUringLoop,
    completion: IoUringLoop.Completion,
) !void {
    const entry: *PendingEntry = @ptrCast(@alignCast(context));
    entry.handle = null;
    entry.result = completion.result;
    entry.completed = true;
}

fn cancelDeadTransactions(self: *NativeServer) !void {
    for (self.pending.items) |pending| {
        var dead = pending.transaction.root.client.state != .active or
            !pending.transaction.root.resource_alive;
        for (pending.transaction.entries) |commit|
            dead = dead or commit.surface.client.state != .active or !commit.surface.resource_alive;
        if (!dead or pending.discarded) continue;
        pending.discarded = true;
        try self.cancelPending(pending);
    }
}

fn cancelPending(self: *NativeServer, pending: *PendingTransaction) !void {
    var first_error: ?anyerror = null;
    for (pending.entries) |*entry| {
        if (entry.copy) |copy| if (!entry.copy_cancel_requested) {
            copy.cancel() catch |err| if (first_error == null) {
                first_error = err;
            };
            entry.copy_cancel_requested = true;
        };
        if (entry.handle) |handle| if (!entry.cancel_requested) {
            self.event_loop.ioLoop().cancel(handle) catch |err| if (first_error == null) {
                first_error = err;
            };
            entry.cancel_requested = true;
        };
    }
    if (first_error) |err| return err;
}

fn pendingIoTerminal(pending: *const PendingTransaction) bool {
    for (pending.entries) |entry| {
        if (entry.handle != null) return false;
        if (entry.copy) |copy| if (!copy.isTerminal()) return false;
    }
    return true;
}

fn progressTransactions(self: *NativeServer) !void {
    const now = self.commit_timing_clock.now(self.io).nanoseconds;
    var index: usize = 0;
    while (index < self.pending.items.len) {
        const pending = self.pending.items[index];
        if (pending.discarded) {
            if (!pendingIoTerminal(pending)) {
                index += 1;
                continue;
            }
            self.destroyPending(index);
            continue;
        }
        if (!self.isRootHead(index)) {
            index += 1;
            continue;
        }
        var ready = true;
        for (pending.transaction.entries, pending.entries) |*commit, *entry| {
            if (commit.surface.client.state != .active or !commit.surface.resource_alive) {
                pending.discarded = true;
                try self.cancelPending(pending);
                ready = false;
                break;
            }
            if (!entry.prepared) {
                if (commit.attachment == .buffer) switch (commit.attachment.buffer.buffer.content) {
                    .shm => self.startShmCopy(entry, commit) catch |err| {
                        pending.discarded = true;
                        self.cancelPending(pending) catch {};
                        if (pendingIoTerminal(pending)) self.destroyPending(index);
                        return err;
                    },
                    .single_pixel => |pixel_value| entry.snapshot = shm.Snapshot.initSinglePixel(
                        self.allocator,
                        pixel_value,
                    ) catch |err| {
                        pending.discarded = true;
                        self.cancelPending(pending) catch {};
                        if (pendingIoTerminal(pending)) self.destroyPending(index);
                        return err;
                    },
                    .dmabuf => {},
                };
                if (commit.synchronization) |synchronization| {
                    if (!synchronization.acquire.signaled()) self.armSyncWait(entry, commit) catch |err| {
                        pending.discarded = true;
                        self.cancelPending(pending) catch {};
                        if (pendingIoTerminal(pending)) self.destroyPending(index);
                        return err;
                    };
                }
                entry.prepared = true;
            }
            if (entry.completed) {
                if (entry.event_fd >= 0) _ = linux.close(entry.event_fd);
                entry.event_fd = -1;
                entry.completed = false;
                if (entry.result != @sizeOf(u64) or entry.event_value == 0) {
                    pending.discarded = true;
                    try self.cancelPending(pending);
                    ready = false;
                    break;
                }
            }
            if (entry.copy) |copy| {
                if (!copy.isTerminal()) {
                    ready = false;
                } else {
                    entry.snapshot = copy.takeSnapshot() catch null;
                    entry.copy_failed = entry.snapshot == null;
                    copy.deinit();
                    entry.copy = null;
                }
            }
            if (entry.handle != null) ready = false;
            if (!commitTimingReady(commit.target_timestamp, now)) {
                ready = false;
                continue;
            }
            if (!entry.protocol_prepared) {
                const applicable = self.prepareCommit(commit, entry) catch |err| {
                    pending.discarded = true;
                    self.cancelPending(pending) catch {};
                    if (isProtocolError(err)) {
                        ready = false;
                        break;
                    }
                    if (pendingIoTerminal(pending)) self.destroyPending(index);
                    return err;
                };
                if (!applicable) {
                    pending.discarded = true;
                    try self.cancelPending(pending);
                    ready = false;
                    break;
                }
                entry.protocol_prepared = true;
            }
            if (commit.fifo_wait and !self.fifoWaitReady(commit.surface)) ready = false;
        }
        if (pending.discarded) {
            if (pendingIoTerminal(pending)) {
                self.destroyPending(index);
                continue;
            }
            index += 1;
            continue;
        }
        if (!ready) {
            index += 1;
            continue;
        }
        self.applyTransaction(pending) catch |err| {
            self.destroyPending(index);
            if (isProtocolError(err)) continue;
            return err;
        };
        self.destroyPending(index);
    }
}

fn commitTimingReady(target: ?i96, now: i96) bool {
    return target == null or target.? <= now;
}

fn scheduleCommitTiming(self: *NativeServer) !void {
    const now = self.commit_timing_clock.now(self.io).nanoseconds;
    const earliest = self.earliestCommitTimestamp(now);
    switch (commitTimingSchedule(self.commit_timing_armed_target, earliest, now)) {
        .unchanged => {},
        .disarm => {
            self.commit_timing_timer.disarm();
            self.commit_timing_armed_target = null;
        },
        .arm => |arm| {
            try self.commit_timing_timer.arm(arm.delay_milliseconds, 0);
            self.commit_timing_armed_target = arm.target;
        },
    }
}

fn earliestCommitTimestamp(self: *const NativeServer, now: i96) ?i96 {
    var earliest: ?i96 = null;
    for (self.pending.items) |pending| {
        if (pending.discarded) continue;
        for (pending.transaction.entries) |commit| {
            const target = commit.target_timestamp orelse continue;
            if (target <= now) continue;
            earliest = if (earliest) |current| @min(current, target) else target;
        }
    }
    return earliest;
}

const CommitTimingSchedule = union(enum) {
    unchanged,
    disarm,
    arm: struct {
        target: i96,
        delay_milliseconds: u64,
    },
};

fn commitTimingSchedule(armed: ?i96, earliest: ?i96, now: i96) CommitTimingSchedule {
    const target = earliest orelse return if (armed == null) .unchanged else .disarm;
    if (armed == target) return .unchanged;
    return .{ .arm = .{
        .target = target,
        .delay_milliseconds = commitTimingDelayMilliseconds(now, target),
    } };
}

fn commitTimingDelayMilliseconds(now: i96, target: i96) u64 {
    std.debug.assert(target > now);
    const delta = target - now;
    const milliseconds = @divTrunc(delta - 1, std.time.ns_per_ms) + 1;
    return @intCast(@min(milliseconds, std.math.maxInt(i32)));
}

fn commitTimingClock(clock_id: u32) !std.Io.Clock {
    if (clock_id == presentation.monotonic_clock_id) return .awake;
    if (clock_id == @as(u32, @intCast(@intFromEnum(std.posix.CLOCK.REALTIME)))) return .real;
    return error.UnsupportedPresentationClock;
}

fn fifoWaitReady(
    self: *const NativeServer,
    surface: *const CompositorGlobal.Surface,
) bool {
    const state = self.findState(surface) orelse return true;
    return !state.fifo_barrier;
}

fn clearFifoBarriers(self: *NativeServer) void {
    for (self.surfaces.items) |state| {
        if (!state.fifo_barrier) continue;
        state.fifo_barrier = false;
        self.fifo_progress_needed = true;
    }
}

fn startShmCopy(
    self: *NativeServer,
    entry: *PendingEntry,
    commit: *const CompositorGlobal.Commit,
) !void {
    const buffer = commit.attachment.buffer.buffer.content.shm;
    const damage: ?[]const render.Rect = if (commit.buffer_damage.len == 0)
        null
    else
        commit.buffer_damage;
    var reuse: ?shm.Snapshot = null;
    defer if (reuse) |*snapshot| snapshot.deinit();
    if (self.findState(commit.surface)) |state| if (state.snapshot) |*snapshot| {
        reuse = .{
            .allocator = self.allocator,
            .size = snapshot.size,
            .pixels = try self.allocator.dupe(u32, snapshot.pixels),
            .force_opaque = snapshot.force_opaque,
            .source_damage = null,
        };
    };
    entry.copy = AsyncShmCopy.create(
        self.allocator,
        self.event_loop.ioLoop(),
        buffer,
        damage,
        if (reuse) |*snapshot| snapshot else null,
        entry,
        copyComplete,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            entry.copy_failed = true;
            return;
        },
    };
    entry.copy.?.start() catch {};
}

fn applyTransaction(self: *NativeServer, pending: *PendingTransaction) !void {
    var callback_batch_count: usize = 0;
    var feedback_batch_count: usize = 0;
    for (pending.transaction.entries) |commit|
        if (commit.frame_callbacks.len != 0) {
            callback_batch_count += 1;
        };
    for (pending.transaction.entries) |commit|
        if (commit.presentation_feedbacks.len != 0) {
            feedback_batch_count += 1;
        };
    try self.frame_callbacks.ensureUnusedCapacity(self.allocator, callback_batch_count);
    try self.presentation_pending.ensureUnusedCapacity(self.allocator, feedback_batch_count);
    for (pending.entries) |*entry| if (entry.layer_shell_commit) |staged| {
        if (!staged.isApplicable()) {
            staged.discard();
            entry.layer_shell_commit = null;
            entry.skip_application = true;
        }
    };
    try self.prepareApplication(pending);
    for (pending.transaction.entries, pending.entries) |*commit, *entry| {
        if (entry.skip_application) continue;
        if (commit.fifo_set) {
            const state = self.findState(commit.surface) orelse unreachable;
            state.fifo_barrier = true;
        }
        try self.applyEntry(commit, entry);
    }
    var layer_shell_changed = false;
    for (pending.entries) |*entry| if (entry.layer_shell_commit) |staged| {
        entry.layer_shell_commit = null;
        if (entry.copy_failed) staged.mapped = false;
        try self.layer_shell.apply(staged);
        layer_shell_changed = true;
    };
    for (pending.transaction.hierarchy_updates) |update| update.apply(update.context);
    var has_direct_update = false;
    for (pending.transaction.entries, pending.entries) |*commit, *entry| if (entry.direct_update) |captured| {
        var update = captured;
        if (entry.copy_failed and commit.attachment == .buffer) {
            update.active = false;
            self.xdg_shell.deactivateFailedBuffer(commit.surface);
            self.layer_shell.deactivateFailedBuffer(commit.surface);
        }
        const current = update.isCurrent();
        update.apply();
        if (current) {
            const activate = try self.xdg_shell.applied(commit.surface, update.active);
            if (activate) try self.activateToplevel(commit.surface);
        }
        has_direct_update = true;
    };
    try self.refreshInputFocus(inputTime(self));
    if (layer_shell_changed) {
        self.repaint_needed = true;
        try self.refreshKeyboardFocus(null);
    }
    const damage_state = if (!self.repaint_needed and
        pending.transaction.entries.len == 1 and
        pending.transaction.hierarchy_updates.len == 0 and !has_direct_update and
        !pending.entries[0].skip_application and
        !self.isCursorSurface(pending.transaction.entries[0].surface) and
        (self.surface_tree.find(pending.transaction.entries[0].surface) orelse unreachable).parent == null)
        self.findState(pending.transaction.entries[0].surface)
    else
        null;
    for (pending.transaction.entries) |*commit| {
        if (try commit.takeFrameCallbacks()) |callbacks|
            self.frame_callbacks.appendAssumeCapacity(callbacks);
    }
    for (pending.transaction.entries, pending.entries) |*commit, *entry| {
        if (entry.skip_application) {
            if (commit.takePresentationFeedbacks()) |feedbacks_value| {
                var feedbacks = feedbacks_value;
                feedbacks.deinit();
            }
            continue;
        }
        self.discardPendingPresentationFor(commit.surface);
        if (commit.takePresentationFeedbacks()) |feedbacks| {
            const state = self.findState(commit.surface) orelse unreachable;
            if (state.snapshot != null or state.dmabuf != null) {
                self.presentation_pending.appendAssumeCapacity(feedbacks);
            } else {
                var discarded = feedbacks;
                discarded.deinit();
            }
        }
    }
    try self.renderScene(damage_state);
}

fn discardPendingPresentationFor(
    self: *NativeServer,
    surface: *CompositorGlobal.Surface,
) void {
    var index: usize = 0;
    while (index < self.presentation_pending.items.len) {
        if (self.presentation_pending.items[index].surface != surface) {
            index += 1;
            continue;
        }
        var feedbacks = self.presentation_pending.orderedRemove(index);
        feedbacks.deinit();
    }
}

fn submitPendingPresentation(self: *NativeServer) void {
    std.debug.assert(self.presentation_submitted.items.len == 0);
    while (self.presentation_pending.items.len != 0) {
        var feedbacks = self.presentation_pending.orderedRemove(0);
        const state = self.findState(feedbacks.surface);
        if (state != null and self.renderer.wasSampled(state.?.sample_tag)) {
            self.presentation_submitted.appendAssumeCapacity(feedbacks);
        } else {
            feedbacks.deinit();
        }
    }
}

fn finishSubmittedPresentation(self: *NativeServer, info: presentation.Info) void {
    for (self.presentation_submitted.items) |*feedbacks| {
        feedbacks.presented(&self.output_global, info);
        feedbacks.deinit();
    }
    self.presentation_submitted.clearRetainingCapacity();
}

fn discardSubmittedPresentation(self: *NativeServer) void {
    for (self.presentation_submitted.items) |*feedbacks| feedbacks.deinit();
    self.presentation_submitted.clearRetainingCapacity();
}

fn discardPresentationFeedbacks(self: *NativeServer) void {
    for (self.presentation_submitted.items) |*feedbacks| feedbacks.deinit();
    self.presentation_submitted.deinit(self.allocator);
    for (self.presentation_pending.items) |*feedbacks| feedbacks.deinit();
    self.presentation_pending.deinit(self.allocator);
}

fn finishFrameCallbacks(self: *NativeServer) !void {
    const now = std.Io.Clock.awake.now(self.io).toMilliseconds();
    const milliseconds: u32 = @truncate(@as(u64, @intCast(@max(now, 0))));
    while (self.frame_callbacks.items.len != 0) {
        var callbacks = self.frame_callbacks.orderedRemove(0);
        callbacks.finish(milliseconds) catch |err| {
            callbacks.deinit();
            return err;
        };
        callbacks.deinit();
    }
}

fn discardDeadFrameCallbacks(self: *NativeServer) void {
    var index: usize = 0;
    while (index < self.frame_callbacks.items.len) {
        if (self.frame_callbacks.items[index].surface.client.state == .active) {
            index += 1;
            continue;
        }
        var callbacks = self.frame_callbacks.orderedRemove(index);
        callbacks.deinit();
    }
}

fn discardFrameCallbacks(self: *NativeServer) void {
    for (self.frame_callbacks.items) |*callbacks| callbacks.deinit();
    self.frame_callbacks.deinit(self.allocator);
}

fn destroyPending(self: *NativeServer, index: usize) void {
    const pending = self.pending.orderedRemove(index);
    std.debug.assert(pendingIoTerminal(pending));
    for (pending.entries) |*entry| {
        if (entry.event_fd >= 0) _ = linux.close(entry.event_fd);
        if (entry.copy) |copy| copy.deinit();
        if (entry.snapshot) |*snapshot| snapshot.deinit();
        if (entry.layer_shell_commit) |staged| staged.discard();
    }
    for (pending.transaction.entries, pending.entries) |*commit, *entry| {
        if (entry.dmabuf_reference_held) {
            commit.attachment.buffer.buffer.unreference();
            entry.dmabuf_reference_held = false;
        }
        if (entry.release_needed) commit.releaseBuffer() catch {};
    }
    self.allocator.free(pending.entries);
    pending.transaction.deinit();
    self.allocator.destroy(pending);
}

fn copyComplete(_: ?*anyopaque, _: *AsyncShmCopy) void {
    // The after-platform phase observes terminal copies independently.
}

fn renderScene(self: *NativeServer, damage_state: ?*SurfaceState) !void {
    if (self.output == .drm) {
        const output = self.output.drm orelse return;
        if (!output.ready()) {
            self.repaint_needed = true;
            return;
        }
    }
    try self.presentation_submitted.ensureUnusedCapacity(
        self.allocator,
        self.presentation_pending.items.len,
    );
    var immediate_presentation: ?presentation.Info = null;
    var commands: std.ArrayList(render.Command) = .empty;
    defer commands.deinit(self.allocator);
    try commands.append(self.allocator, .{ .clear = render.Color.rgba(0, 0, 0, 0) });
    var paint_entries: std.ArrayList(SurfaceTree.PaintEntry) = .empty;
    defer paint_entries.deinit(self.allocator);
    try self.collectRootPaintEntries(&paint_entries);
    try self.appendSurfaceCommands(paint_entries.items, &commands);
    paint_entries.clearRetainingCapacity();
    const desktop_command_count = commands.items.len;
    if (self.pointer_cursor.current()) |cursor| switch (cursor) {
        .surface => |surface| {
            try self.appendCursorPaint(surface.root, surface.x, surface.y, &paint_entries);
            try self.appendSurfaceCommands(paint_entries.items, &commands);
            paint_entries.clearRetainingCapacity();
        },
        .shape => |shape| try appendShapeCursorCommand(
            shape.buffer,
            shape.x,
            shape.y,
            &commands,
            self.allocator,
        ),
    };
    var cursors = self.tablet_global.cursorIterator();
    while (cursors.next()) |cursor| switch (cursor) {
        .surface => |surface| {
            try self.appendCursorPaint(surface.root, surface.x, surface.y, &paint_entries);
            try self.appendSurfaceCommands(paint_entries.items, &commands);
            paint_entries.clearRetainingCapacity();
        },
        .shape => |shape| try appendShapeCursorCommand(
            shape.buffer,
            shape.x,
            shape.y,
            &commands,
            self.allocator,
        ),
    };
    var damage_storage: [1]render.Rect = undefined;
    const damage = if (damage_state) |state| self.frameDamage(state, &damage_storage) else null;
    switch (self.output) {
        .headless => |*output| {
            try self.renderer.beginFrame(output.renderTarget(), output.scale, .{}, damage, .{});
            var frame_active = true;
            errdefer if (frame_active) self.renderer.cancelFrame();
            try self.renderer.append(commands.items);
            frame_active = false;
            try self.renderer.finishFrame();
            immediate_presentation = presentation.Info.now(self.io);
            immediate_presentation.?.refresh_nanoseconds = output.refreshNanoseconds();
        },
        .drm => |maybe_output| {
            const output = maybe_output orelse return;
            const target = output.acquire() orelse {
                self.repaint_needed = true;
                return;
            };
            var output_frame_active = true;
            defer if (output_frame_active) output.cancel();
            var frame_damage = Region.init();
            defer frame_damage.deinit();
            const size = output.size;
            frame_damage.setRectangle(0, 0, size.width, size.height);
            try output.repairDamage(&frame_damage);
            try self.renderer.beginFrame(target, output.scale, .{}, null, output.colorDescription());
            var renderer_frame_active = true;
            errdefer if (renderer_frame_active) self.renderer.cancelFrame();
            try self.renderer.append(commands.items);
            renderer_frame_active = false;
            const completion = try self.renderer.finishFrameScanout(null);
            defer if (completion.sync_file_fd) |fd| {
                _ = std.c.close(fd);
            };
            immediate_presentation = output.present(
                &frame_damage,
                completion.sync_file_fd,
                false,
            ) catch |err| switch (err) {
                error.OutputBusy => {
                    if (self.output_busy_retries == maximum_output_busy_retries)
                        return error.OutputBusy;
                    self.output_busy_retries += 1;
                    // Kernel EBUSY does not imply that a tracked page flip will
                    // produce a ready event, so retry from an io_uring timer turn.
                    self.scheduleRepaint(1);
                    return;
                },
                else => return err,
            };
            output_frame_active = false;
            self.output_busy_retries = 0;
        },
    }
    // Ignoring barriers for surfaces absent from this frame prevents an
    // unmapped set->wait sequence from blocking its first buffer forever.
    self.clearFifoBarriers();
    self.submitPendingPresentation();
    self.repaint_needed = false;
    self.screencopy_global.composedFrame(
        commands.items[0..desktop_command_count],
        commands.items,
        self.output.scale(),
        self.output.modeSize(),
        presentation.Info.now(self.io).timestamp,
    );
    self.surface_tree.redrawHandled();
    if (damage_state) |state| state.full_damage = false;
    self.frame_count +%= 1;
    try self.finishFrameCallbacks();
    if (immediate_presentation) |info| self.finishSubmittedPresentation(info);
}

fn appendSurfaceCommands(
    self: *NativeServer,
    paint_entries: []const SurfaceTree.PaintEntry,
    commands: *std.ArrayList(render.Command),
) !void {
    for (paint_entries) |paint_entry| {
        const state = self.findState(paint_entry.surface) orelse continue;
        if (!state.surface.resource_alive) continue;
        var pixel_buffer: render.PixelBuffer = if (state.dmabuf) |dmabuf_state| blk: {
            const dmabuf = dmabuf_state.buffer.content.dmabuf;
            const format = render.DmabufFormat.fromFourcc(dmabuf.source.format) orelse continue;
            break :blk .{
                .size = dmabuf.size,
                .stride_pixels = if (format.isPackedRgb())
                    dmabuf.source.planes[0].stride / @sizeOf(u32)
                else
                    dmabuf.size.width,
                .dmabuf = dmabuf.source,
                .source_cache = dmabuf_state.source_cache,
            };
        } else if (state.snapshot) |*value| value.pixelBuffer() else continue;
        const format = if (pixel_buffer.dmabuf) |dmabuf|
            render.DmabufFormat.fromFourcc(dmabuf.format) orelse continue
        else
            render.DmabufFormat.argb8888;
        pixel_buffer.color_representation = state.color_representation.toRender(format);
        const transform = bufferTransform(state.transform);
        const geometry = surface_geometry.calculate(
            pixel_buffer.size,
            state.scale,
            @intCast(state.transform),
            state.viewport,
            false,
        ) catch continue;
        const image_x = paint_entry.x +| state.x;
        const image_y = paint_entry.y +| state.y;
        const force_opaque = if (pixel_buffer.dmabuf) |source|
            source.force_opaque
        else
            state.snapshot.?.force_opaque;
        const region_covers_buffer = state.opaque_region.coversRectangle(
            state.x,
            state.y,
            geometry.logical_size.width,
            geometry.logical_size.height,
        );
        try commands.append(self.allocator, .{ .image = .{
            .x = image_x,
            .y = image_y,
            .size = geometry.logical_size,
            .buffer = pixel_buffer,
            .sample_tag = state.sample_tag,
            .source = geometry.source,
            .transform = transform,
            .is_opaque = force_opaque or region_covers_buffer,
            .alpha_multiplier = state.alpha_multiplier,
            .opaque_region = if (force_opaque or region_covers_buffer)
                .{}
            else
                surfaceOpaqueRegion(
                    &state.opaque_region,
                    .{
                        .x = state.x,
                        .y = state.y,
                        .width = geometry.logical_size.width,
                        .height = geometry.logical_size.height,
                    },
                    paint_entry.x,
                    paint_entry.y,
                ),
        } });
    }
}

fn appendShapeCursorCommand(
    buffer: render.PixelBuffer,
    x: i32,
    y: i32,
    commands: *std.ArrayList(render.Command),
    allocator: std.mem.Allocator,
) !void {
    try commands.append(allocator, .{ .image = .{
        .x = x,
        .y = y,
        .size = buffer.size,
        .buffer = buffer,
    } });
}

fn appendCursorPaint(
    self: *NativeServer,
    root: *CompositorGlobal.Surface,
    x: i32,
    y: i32,
    paint_entries: *std.ArrayList(SurfaceTree.PaintEntry),
) !void {
    const node = self.surface_tree.find(root) orelse return;
    if (node.parent != null) return;
    const first = paint_entries.items.len;
    try self.surface_tree.paint(node, paint_entries);
    for (paint_entries.items[first..]) |*entry| {
        entry.x +|= x;
        entry.y +|= y;
    }
}

fn frameDamage(
    self: *const NativeServer,
    state: *const SurfaceState,
    storage: *[1]render.Rect,
) ?[]const render.Rect {
    if (state.full_damage) return null;
    if (state.dmabuf != null) return null;
    if (state.viewport.source != null or state.viewport.destination != null) return null;
    const snapshot = if (state.snapshot) |*value| value else return null;
    const source_damage = snapshot.source_damage orelse return null;
    const transform = bufferTransform(state.transform);
    var bounds: ?render.Rect = null;
    for (source_damage) |rectangle| {
        const mapped = mapBufferDamage(
            rectangle,
            snapshot.size,
            transform,
            @intCast(state.scale),
            .{ .x = state.x, .y = state.y },
            self.output.scale(),
            self.output.modeSize(),
        ) orelse continue;
        bounds = if (bounds) |existing| existing.unionWith(mapped) else mapped;
    }
    if (bounds) |rectangle| {
        storage[0] = rectangle;
        return storage[0..1];
    }
    return &.{};
}

fn mapBufferDamage(
    rectangle: render.Rect,
    buffer_size: render.Size,
    transform: render.BufferTransform,
    buffer_scale: u32,
    position: render.Position,
    output_scale: render.Scale,
    output_size: render.Size,
) ?render.Rect {
    std.debug.assert(buffer_scale > 0 and output_scale.numerator > 0);
    const width: i128 = buffer_size.width;
    const height: i128 = buffer_size.height;
    const transformed_size = transform.applyToSize(buffer_size);
    const logical_width = @max(transformed_size.width / buffer_scale, 1);
    const logical_height = @max(transformed_size.height / buffer_scale, 1);
    const numerator: i128 = output_scale.numerator;
    const denominator: i128 = render.Scale.denominator;
    const output_width = @divTrunc(@as(i128, logical_width) * numerator + denominator / 2, denominator);
    const output_height = @divTrunc(@as(i128, logical_height) * numerator + denominator / 2, denominator);
    const filter_margin: i128 = if (output_width != transformed_size.width or
        output_height != transformed_size.height) 1 else 0;
    const x0 = @max(@as(i128, rectangle.x) - filter_margin, 0);
    const y0 = @max(@as(i128, rectangle.y) - filter_margin, 0);
    const x1 = @min(@as(i128, rectangle.x) + rectangle.width + filter_margin, width);
    const y1 = @min(@as(i128, rectangle.y) + rectangle.height + filter_margin, height);
    const transformed = switch (transform) {
        .normal => .{ x0, y0, x1, y1 },
        .rotate_90 => .{ height - y1, x0, height - y0, x1 },
        .rotate_180 => .{ width - x1, height - y1, width - x0, height - y0 },
        .rotate_270 => .{ y0, width - x1, y1, width - x0 },
        .flipped => .{ width - x1, y0, width - x0, y1 },
        .flipped_90 => .{ height - y1, width - x1, height - y0, width - x0 },
        .flipped_180 => .{ x0, height - y1, x1, height - y0 },
        .flipped_270 => .{ y0, x0, y1, x1 },
    };
    const scale: i128 = buffer_scale;
    const logical_left = @divFloor(transformed[0], scale) + position.x;
    const logical_top = @divFloor(transformed[1], scale) + position.y;
    const logical_right = -@divFloor(-transformed[2], scale) + position.x;
    const logical_bottom = -@divFloor(-transformed[3], scale) + position.y;
    const left = @max(@divFloor(logical_left * numerator, denominator), 0);
    const top = @max(@divFloor(logical_top * numerator, denominator), 0);
    const right = @min(
        -@divFloor(-(logical_right * numerator), denominator),
        output_size.width,
    );
    const bottom = @min(
        -@divFloor(-(logical_bottom * numerator), denominator),
        output_size.height,
    );
    if (left >= right or top >= bottom) return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

fn bufferTransform(value: u32) render.BufferTransform {
    return switch (value) {
        0 => .normal,
        1 => .rotate_90,
        2 => .rotate_180,
        3 => .rotate_270,
        4 => .flipped,
        5 => .flipped_90,
        6 => .flipped_180,
        7 => .flipped_270,
        else => unreachable,
    };
}

fn stateFor(self: *NativeServer, surface: *CompositorGlobal.Surface) !*SurfaceState {
    if (self.findState(surface)) |state| return state;
    const sample_tag = self.next_surface_sample_tag;
    self.next_surface_sample_tag = std.math.add(
        u64,
        self.next_surface_sample_tag,
        1,
    ) catch return error.SurfaceSampleTagExhausted;
    const state = try self.allocator.create(SurfaceState);
    errdefer self.allocator.destroy(state);
    try surface.reference();
    errdefer surface.unreference();
    state.* = .{
        .surface = surface,
        .sample_tag = sample_tag,
        .opaque_region = Region.init(),
        .input_region = CompositorGlobal.InputRegion.init(),
    };
    errdefer state.opaque_region.deinit();
    errdefer state.input_region.deinit();
    try self.surfaces.append(self.allocator, state);
    return state;
}

fn surfaceOpaqueRegion(
    region: *const Region,
    buffer_bounds: render.Rect,
    surface_x: i32,
    surface_y: i32,
) render.OpaqueRegion {
    var result: render.OpaqueRegion = .{};
    var rectangles = region.rectangleIterator();
    while (rectangles.next()) |rectangle| {
        const clipped = (render.Rect{
            .x = rectangle.x,
            .y = rectangle.y,
            .width = rectangle.width,
            .height = rectangle.height,
        }).intersection(buffer_bounds) orelse continue;
        if (!result.append(clipped.translated(surface_x, surface_y))) break;
    }
    return result;
}

fn findState(self: *const NativeServer, surface: *const CompositorGlobal.Surface) ?*SurfaceState {
    for (self.surfaces.items) |state| if (state.surface == surface) return state;
    return null;
}

fn xdgSurfaceSize(context: *anyopaque, surface: *const CompositorGlobal.Surface) ?render.Size {
    const self: *const NativeServer = @ptrCast(@alignCast(context));
    const state = self.findState(surface) orelse return null;
    const buffer_size = if (state.dmabuf) |dmabuf|
        dmabuf.buffer.content.dmabuf.size
    else if (state.snapshot) |*snapshot|
        snapshot.size
    else
        return null;
    return (surface_geometry.calculate(
        buffer_size,
        state.scale,
        @intCast(state.transform),
        state.viewport,
        false,
    ) catch return null).logical_size;
}

fn xdgOutputBounds(context: *anyopaque) render.Rect {
    const self: *const NativeServer = @ptrCast(@alignCast(context));
    return self.layer_shell.usableBounds();
}

fn layerShellChanged(context: *anyopaque) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.repaint_needed = true;
    self.refreshKeyboardFocus(null) catch self.terminate();
}

fn layerShellDeactivated(
    context: *anyopaque,
    surface: *CompositorGlobal.Surface,
) void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.deactivateLayerSurface(surface) catch self.terminate();
}

fn deactivateLayerSurface(
    self: *NativeServer,
    surface: *CompositorGlobal.Surface,
) !void {
    const state = self.findState(surface) orelse return;
    if (state.snapshot) |*snapshot| snapshot.deinit();
    state.snapshot = null;
    if (state.dmabuf) |*dmabuf| dmabuf.deinit(surface.client, true);
    state.dmabuf = null;
    state.fifo_barrier = false;
    self.discardPendingPresentationFor(surface);
    try self.output_global.setSurfaceVisible(surface, false);
}

fn pruneSurfaces(self: *NativeServer) bool {
    var removed = false;
    var index: usize = 0;
    while (index < self.surfaces.items.len) {
        const state = self.surfaces.items[index];
        var pending_state = false;
        for (self.pending.items) |pending| {
            for (pending.transaction.entries) |*commit| {
                if (commit.surface == state.surface) pending_state = true;
            }
        }
        if (state.surface.resource_alive or pending_state) {
            index += 1;
            continue;
        }
        self.output_global.setSurfaceVisible(state.surface, false) catch {};
        state.deinit(self.allocator);
        _ = self.surfaces.orderedRemove(index);
        removed = true;
    }
    return removed;
}

const SocketSelection = struct { name: []u8, path: [:0]u8 };

fn selectSocket(allocator: std.mem.Allocator, options: Options) !SocketSelection {
    const requested = options.display_name;
    if (requested) |name| {
        if (name.len == 0) return error.InvalidDisplayName;
        if (name[0] == '/') {
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            return .{
                .name = owned_name,
                .path = try allocator.dupeZ(u8, name),
            };
        }
        const runtime_dir = options.runtime_directory orelse processEnvironment("XDG_RUNTIME_DIR") orelse
            return error.MissingRuntimeDirectory;
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ runtime_dir, name }, 0);
        errdefer allocator.free(path);
        return .{ .name = try allocator.dupe(u8, name), .path = path };
    }
    const runtime_dir = options.runtime_directory orelse processEnvironment("XDG_RUNTIME_DIR") orelse
        return error.MissingRuntimeDirectory;
    var index: u32 = 0;
    while (index < 1024) : (index += 1) {
        const name = try std.fmt.allocPrint(allocator, "wayland-{d}", .{index});
        errdefer allocator.free(name);
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ runtime_dir, name }, 0);
        if (std.c.access(path.ptr, 0) != 0) return .{ .name = name, .path = path };
        allocator.free(path);
        allocator.free(name);
    }
    return error.NoDisplayAvailable;
}

fn bindListener(path: [:0]const u8, backlog: u31) !i32 {
    if (path.len >= @sizeOf(@FieldType(linux.sockaddr.un, "path"))) return error.NameTooLong;
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    @memset(&address.path, 0);
    @memcpy(address.path[0..path.len], path);
    const result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(result) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(result);
    errdefer _ = linux.close(fd);
    const length: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
    if (linux.errno(linux.bind(fd, @ptrCast(&address), length)) != .SUCCESS)
        return error.DisplayInUse;
    errdefer _ = std.c.unlink(path.ptr);
    if (linux.errno(linux.listen(fd, backlog)) != .SUCCESS) return error.ListenFailed;
    return fd;
}

fn processEnvironment(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

test "buffer damage maps through every surface transform" {
    const source: render.Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    const size: render.Size = .{ .width = 2, .height = 3 };
    const Case = struct {
        transform: render.BufferTransform,
        expected: render.Rect,
    };
    const cases = [_]Case{
        .{ .transform = .normal, .expected = .{ .x = 0, .y = 0, .width = 1, .height = 1 } },
        .{ .transform = .rotate_90, .expected = .{ .x = 2, .y = 0, .width = 1, .height = 1 } },
        .{ .transform = .rotate_180, .expected = .{ .x = 1, .y = 2, .width = 1, .height = 1 } },
        .{ .transform = .rotate_270, .expected = .{ .x = 0, .y = 1, .width = 1, .height = 1 } },
        .{ .transform = .flipped, .expected = .{ .x = 1, .y = 0, .width = 1, .height = 1 } },
        .{ .transform = .flipped_90, .expected = .{ .x = 2, .y = 1, .width = 1, .height = 1 } },
        .{ .transform = .flipped_180, .expected = .{ .x = 0, .y = 2, .width = 1, .height = 1 } },
        .{ .transform = .flipped_270, .expected = .{ .x = 0, .y = 0, .width = 1, .height = 1 } },
    };
    for (cases) |case| try std.testing.expectEqual(
        case.expected,
        mapBufferDamage(source, size, case.transform, 1, .{}, .{}, .{ .width = 3, .height = 3 }).?,
    );
}

test "root-head scheduler preserves per-root FIFO and unrelated progress" {
    const root_a: *CompositorGlobal.Surface = @ptrFromInt(0x1000);
    const root_b: *CompositorGlobal.Surface = @ptrFromInt(0x2000);
    const popup_a: *CompositorGlobal.Surface = @ptrFromInt(0x3000);
    var pending_entries: [3][0]PendingEntry = .{ .{}, .{}, .{} };
    var transaction_entries: [3][0]CompositorGlobal.Commit = .{ .{}, .{}, .{} };
    var transactions = [_]PendingTransaction{
        .{ .transaction = .{ .allocator = std.testing.allocator, .root = root_a, .entries = &transaction_entries[0], .hierarchy_updates = &.{} }, .entries = &pending_entries[0] },
        .{ .transaction = .{ .allocator = std.testing.allocator, .root = popup_a, .entries = &transaction_entries[1], .hierarchy_updates = &.{} }, .entries = &pending_entries[1] },
        .{ .transaction = .{ .allocator = std.testing.allocator, .root = root_b, .entries = &transaction_entries[2], .hierarchy_updates = &.{} }, .entries = &pending_entries[2] },
    };
    var pointers = [_]*PendingTransaction{ &transactions[0], &transactions[1], &transactions[2] };
    var root_node: SurfaceTree.Node = .{ .surface = root_a };
    var popup_node: SurfaceTree.Node = .{ .surface = popup_a, .parent = &root_node };
    var tree_nodes = [_]*SurfaceTree.Node{ &root_node, &popup_node };
    var server: NativeServer = undefined;
    server.pending = .empty;
    server.pending.items = &pointers;
    server.surface_tree = SurfaceTree.init(std.testing.allocator);
    server.surface_tree.nodes.items = &tree_nodes;

    try std.testing.expect(server.isRootHead(0));
    try std.testing.expect(!server.isRootHead(1));
    try std.testing.expect(server.isRootHead(2));
    try std.testing.expect(!commitTimingReady(200, 100));
    try std.testing.expect(commitTimingReady(100, 100));
    try std.testing.expect(commitTimingReady(null, 100));
}

test "commit timing scheduling deduplicates and clamps distant deadlines" {
    try std.testing.expectEqual(std.Io.Clock.awake, try commitTimingClock(
        presentation.monotonic_clock_id,
    ));
    try std.testing.expectEqual(std.Io.Clock.real, try commitTimingClock(
        @intCast(@intFromEnum(std.posix.CLOCK.REALTIME)),
    ));
    try std.testing.expectError(error.UnsupportedPresentationClock, commitTimingClock(
        std.math.maxInt(u32),
    ));

    switch (commitTimingSchedule(null, 1_000_000, 0)) {
        .arm => |arm| {
            try std.testing.expectEqual(@as(i96, 1_000_000), arm.target);
            try std.testing.expectEqual(@as(u64, 1), arm.delay_milliseconds);
        },
        else => return error.ExpectedArm,
    }
    try std.testing.expect(commitTimingSchedule(1_000_000, 1_000_000, 0) == .unchanged);
    try std.testing.expect(commitTimingSchedule(1_000_000, null, 0) == .disarm);
    try std.testing.expect(commitTimingSchedule(null, null, 0) == .unchanged);
    try std.testing.expectEqual(
        @as(u64, 2),
        commitTimingDelayMilliseconds(0, std.time.ns_per_ms + 1),
    );
    try std.testing.expectEqual(
        @as(u64, std.math.maxInt(i32)),
        commitTimingDelayMilliseconds(
            0,
            (@as(i96, std.math.maxInt(i32)) + 1) * std.time.ns_per_ms,
        ),
    );
}

test "native accepted frames clear mapped and configure-only FIFO barriers" {
    var mapped_surface: CompositorGlobal.Surface = undefined;
    var configure_only_surface: CompositorGlobal.Surface = undefined;
    var missing_surface: CompositorGlobal.Surface = undefined;
    var mapped_state: SurfaceState = undefined;
    mapped_state.surface = &mapped_surface;
    mapped_state.fifo_barrier = true;
    var configure_only_state: SurfaceState = undefined;
    configure_only_state.surface = &configure_only_surface;
    configure_only_state.fifo_barrier = true;

    var server: NativeServer = undefined;
    server.surfaces = .empty;
    defer server.surfaces.deinit(std.testing.allocator);
    try server.surfaces.append(std.testing.allocator, &mapped_state);
    try server.surfaces.append(std.testing.allocator, &configure_only_state);
    server.fifo_progress_needed = false;

    try std.testing.expect(!server.fifoWaitReady(&mapped_surface));
    try std.testing.expect(!server.fifoWaitReady(&configure_only_surface));
    try std.testing.expect(server.fifoWaitReady(&missing_surface));

    server.clearFifoBarriers();
    try std.testing.expect(server.fifoWaitReady(&mapped_surface));
    try std.testing.expect(server.fifoWaitReady(&configure_only_surface));
    try std.testing.expect(server.fifo_progress_needed);
}

test "buffer damage maps scales positions and output clipping conservatively" {
    try std.testing.expectEqual(
        render.Rect{ .x = 0, .y = 1, .width = 4, .height = 4 },
        mapBufferDamage(
            .{ .x = 2, .y = 2, .width = 4, .height = 4 },
            .{ .width = 8, .height = 8 },
            .normal,
            2,
            .{ .x = -1, .y = 1 },
            .{ .numerator = 180 },
            .{ .width = 4, .height = 5 },
        ).?,
    );
    try std.testing.expectEqual(
        null,
        mapBufferDamage(
            .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .{ .width = 1, .height = 1 },
            .normal,
            1,
            .{ .x = -2, .y = -2 },
            .{},
            .{ .width = 1, .height = 1 },
        ),
    );
}

test "native input coordinates respect fractional scale and protocol bounds" {
    try std.testing.expectEqual(@as(f64, 80), physicalToLogicalScale(120, .{ .numerator = 180 }));
    try std.testing.expectEqual(@as(f64, 120), logicalToPhysicalScale(80, .{ .numerator = 180 }));
    try std.testing.expectEqual(@as(f64, 0), clampPointerCoordinate(-1, 64));
    try std.testing.expectEqual(@as(f64, 63), clampPointerCoordinate(80, 64));
    try std.testing.expectEqual(@as(f64, 10), clampVirtualPointerCoordinate(-1, 10, 64));
    try std.testing.expectEqual(@as(f64, 73), clampVirtualPointerCoordinate(80, 10, 64));
    try std.testing.expectEqual(
        @as(f64, 41.5),
        normalizedVirtualPointerCoordinate(50, 100, 10, 64),
    );
    try std.testing.expectEqual(
        @as(f64, 73),
        normalizedVirtualPointerCoordinate(200, 100, 10, 64),
    );
    try std.testing.expectEqual(@as(i32, 384), fixedFromDouble(1.5));
    try std.testing.expectEqual(std.math.minInt(i32), fixedFromDouble(-1.0e20));
    try std.testing.expectEqual(std.math.maxInt(i32), fixedFromDouble(1.0e20));
}

test "transient input position buttons and keyboard focus are seat scoped" {
    const allocator = std.testing.allocator;
    var native: NativeServer = undefined;
    native.allocator = allocator;
    native.server = Server.init(allocator);
    defer native.server.deinit();
    try native.compositor_global.init(allocator, &native.server);
    defer native.compositor_global.deinit();
    try native.seat_global.init(allocator, &native.server, "default", 0, null);
    defer native.seat_global.deinit();
    var transient_seat: SeatGlobal = undefined;
    try transient_seat.init(allocator, &native.server, "transient", 0, null);
    defer transient_seat.deinit();
    native.surface_tree = SurfaceTree.init(allocator);
    defer native.surface_tree.deinit();
    native.surfaces = .empty;
    defer {
        for (native.surfaces.items) |state| state.deinit(allocator);
        native.surfaces.deinit(allocator);
    }
    native.routed_buttons = .empty;
    defer native.routed_buttons.deinit(allocator);

    const client = try native.server.createClient();
    defer native.server.destroyClient(client) catch unreachable;
    const surface = try allocator.create(CompositorGlobal.Surface);
    var surface_initialized = false;
    var surface_error_owned = true;
    errdefer if (surface_error_owned) {
        if (surface_initialized) surface.unreference() else allocator.destroy(surface);
    };
    try client.reference();
    surface.* = .{
        .allocator = allocator,
        .owner = &native.compositor_global,
        .client = client,
        .resource = .{ .id = 100, .generation = 1 },
        .pending_opaque = Region.init(),
        .pending_input = CompositorGlobal.InputRegion.init(),
    };
    surface_initialized = true;
    defer surface.unreference();
    surface_error_owned = false;
    const state = try allocator.create(SurfaceState);
    var state_initialized = false;
    var state_error_owned = true;
    errdefer if (state_error_owned) {
        if (state_initialized) state.deinit(allocator) else allocator.destroy(state);
    };
    try surface.reference();
    state.* = .{
        .surface = surface,
        .sample_tag = 1,
        .opaque_region = Region.init(),
        .input_region = CompositorGlobal.InputRegion.init(),
    };
    state_initialized = true;
    try native.surfaces.append(allocator, state);
    state_error_owned = false;
    const node = try native.surface_tree.nodeFor(surface);
    node.current_active = true;

    transient_seat.setLogicalPointerPosition(17, 23);
    try std.testing.expectEqual(@as(f64, 17), native.pointerLogicalX(&transient_seat));
    try std.testing.expectEqual(@as(f64, 23), native.pointerLogicalY(&transient_seat));
    try native.routed_buttons.append(allocator, .{
        .seat = &native.seat_global,
        .source = .{ .virtual = 1 },
        .button = 0x110,
    });
    try native.routed_buttons.append(allocator, .{
        .seat = &transient_seat,
        .source = .{ .virtual = 1 },
        .button = 0x110,
    });
    try std.testing.expect(native.buttonHeld(&native.seat_global, 0x110));
    try std.testing.expect(native.buttonHeld(&transient_seat, 0x110));
    native.removeRoutedButtonsForSeat(&transient_seat);
    try std.testing.expect(native.buttonHeld(&native.seat_global, 0x110));
    try std.testing.expect(!native.buttonHeld(&transient_seat, 0x110));

    try transient_seat.addVirtualKeyboard();
    try native.refreshTransientKeyboardFocus(&transient_seat, surface);
    try std.testing.expectEqual(surface, transient_seat.keyboardFocus().?);
    try std.testing.expect(native.seat_global.keyboardFocus() == null);
    try transient_seat.removeVirtualKeyboard();
    try std.testing.expect(transient_seat.keyboardFocus() == null);
}

test "output-dependent input callbacks are inert after output loss" {
    const invoke = struct {
        fn callbacks(server: *NativeServer) void {
            nativePointerMotion(server, 1, 0, 1, 2);
            nativePointerRelativeMotion(server, 1, 0, 1, 2, 1, 2);
            nativePointerButton(server, 1, 0, 0x110, .pressed);
            nativeTouchDown(server, 1, 0, 1, 1, 2);
            nativeTouchMotion(server, 1, 0, 1, 2, 3);
            nativeTabletToolProximity(server, 1, 1, 0, 1, 2, true, .{});
            nativeTabletToolAxis(server, 1, 1, 0, .{ .position = .{ .x = 1, .y = 2 } });
            nativeTabletToolTip(server, 1, 1, 0, .{ .position = .{ .x = 1, .y = 2 } }, true);
            nativeTabletToolButton(
                server,
                1,
                1,
                0,
                .{ .position = .{ .x = 1, .y = 2 } },
                1,
                true,
            );
            virtualPointerCapabilityChanged(server, &server.seat_global);
            virtualPointerEvent(server, &server.seat_global, null, 1, .frame);
        }
    }.callbacks;

    var server: NativeServer = undefined;
    server.terminating = true;
    invoke(&server);

    server.terminating = false;
    server.output = .{ .drm = null };
    invoke(&server);
    try std.testing.expect(!try server.refreshPointerFocus(&server.seat_global, 0));
    try server.routeTouchDown(1, 0, 1, 1, 2);
    try server.routeTouchMotion(1, 0, 1, 2, 3);
    try std.testing.expect(try server.tabletFocus(1, 2) == null);
}

test "surface opaque hints clip to offset buffer bounds and translate globally" {
    var region = Region.init();
    defer region.deinit();
    try region.add(-2, 1, 6, 4);
    try region.add(8, 8, 2, 2);

    const opaque_hint = surfaceOpaqueRegion(
        &region,
        .{ .x = 2, .y = 3, .width = 4, .height = 3 },
        10,
        20,
    );
    try std.testing.expectEqualSlices(
        render.Rect,
        &.{.{ .x = 12, .y = 23, .width = 2, .height = 2 }},
        opaque_hint.slice(),
    );
}

test "native presentation reports only renderer-sampled surfaces" {
    const Counter = struct {
        presented_count: usize = 0,
        discarded_count: usize = 0,

        fn presented(
            context: *anyopaque,
            _: *anyopaque,
            _: presentation.Info,
        ) void {
            const counter: *@This() = @ptrCast(@alignCast(context));
            counter.presented_count += 1;
        }

        fn discarded(context: *anyopaque) void {
            const counter: *@This() = @ptrCast(@alignCast(context));
            counter.discarded_count += 1;
        }
    };

    const size: render.Size = .{ .width = 2, .height = 1 };
    var lower_pixels = [_]u32{0xffff0000} ** 2;
    var upper_pixels = [_]u32{0xff00ff00} ** 2;
    const commands = [_]render.Command{
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{ .size = size, .stride_pixels = size.width, .pixels = &lower_pixels },
            .sample_tag = 1,
            .is_opaque = true,
        } },
        .{ .image = .{
            .x = 0,
            .y = 0,
            .size = size,
            .buffer = .{ .size = size, .stride_pixels = size.width, .pixels = &upper_pixels },
            .sample_tag = 2,
            .is_opaque = true,
        } },
        .{ .image = .{
            .x = 2,
            .y = 0,
            .size = size,
            .buffer = .{ .size = size, .stride_pixels = size.width, .pixels = &upper_pixels },
            .sample_tag = 3,
            .is_opaque = true,
        } },
    };
    var target_pixels = [_]u32{0} ** 2;
    var server: NativeServer = undefined;
    server.allocator = std.testing.allocator;
    server.renderer = try Renderer.init(std.testing.allocator, .cpu);
    defer server.renderer.deinit();
    try server.renderer.render(
        .{ .size = size, .commands = &commands },
        .{ .size = size, .stride_pixels = size.width, .pixels = &target_pixels },
    );

    var lower_surface: CompositorGlobal.Surface = undefined;
    lower_surface.references = 2;
    var upper_surface: CompositorGlobal.Surface = undefined;
    upper_surface.references = 2;
    var off_output_surface: CompositorGlobal.Surface = undefined;
    off_output_surface.references = 2;
    var lower_state: SurfaceState = undefined;
    lower_state.surface = &lower_surface;
    lower_state.sample_tag = 1;
    var upper_state: SurfaceState = undefined;
    upper_state.surface = &upper_surface;
    upper_state.sample_tag = 2;
    var off_output_state: SurfaceState = undefined;
    off_output_state.surface = &off_output_surface;
    off_output_state.sample_tag = 3;

    var lower_counter: Counter = .{};
    var upper_counter: Counter = .{};
    var off_output_counter: Counter = .{};
    var lower_feedback: CompositorGlobal.PresentationFeedback = .{
        .context = &lower_counter,
        .presented = Counter.presented,
        .discarded = Counter.discarded,
    };
    var upper_feedback: CompositorGlobal.PresentationFeedback = .{
        .context = &upper_counter,
        .presented = Counter.presented,
        .discarded = Counter.discarded,
    };
    var off_output_feedback: CompositorGlobal.PresentationFeedback = .{
        .context = &off_output_counter,
        .presented = Counter.presented,
        .discarded = Counter.discarded,
    };
    const lower_feedbacks = try std.testing.allocator.dupe(
        *CompositorGlobal.PresentationFeedback,
        &.{&lower_feedback},
    );
    var lower_feedbacks_owned = true;
    errdefer if (lower_feedbacks_owned) std.testing.allocator.free(lower_feedbacks);
    const upper_feedbacks = try std.testing.allocator.dupe(
        *CompositorGlobal.PresentationFeedback,
        &.{&upper_feedback},
    );
    var upper_feedbacks_owned = true;
    errdefer if (upper_feedbacks_owned) std.testing.allocator.free(upper_feedbacks);
    const off_output_feedbacks = try std.testing.allocator.dupe(
        *CompositorGlobal.PresentationFeedback,
        &.{&off_output_feedback},
    );
    var off_output_feedbacks_owned = true;
    errdefer if (off_output_feedbacks_owned)
        std.testing.allocator.free(off_output_feedbacks);

    server.surfaces = .empty;
    defer server.surfaces.deinit(std.testing.allocator);
    try server.surfaces.append(std.testing.allocator, &lower_state);
    try server.surfaces.append(std.testing.allocator, &upper_state);
    try server.surfaces.append(std.testing.allocator, &off_output_state);
    server.presentation_pending = .empty;
    server.presentation_submitted = .empty;
    defer {
        for (server.presentation_submitted.items) |*feedbacks| feedbacks.deinit();
        server.presentation_submitted.deinit(std.testing.allocator);
        for (server.presentation_pending.items) |*feedbacks| feedbacks.deinit();
        server.presentation_pending.deinit(std.testing.allocator);
    }
    try server.presentation_submitted.ensureUnusedCapacity(std.testing.allocator, 3);
    try server.presentation_pending.append(std.testing.allocator, .{
        .allocator = std.testing.allocator,
        .surface = &lower_surface,
        .feedbacks = lower_feedbacks,
    });
    lower_feedbacks_owned = false;
    try server.presentation_pending.append(std.testing.allocator, .{
        .allocator = std.testing.allocator,
        .surface = &upper_surface,
        .feedbacks = upper_feedbacks,
    });
    upper_feedbacks_owned = false;
    try server.presentation_pending.append(std.testing.allocator, .{
        .allocator = std.testing.allocator,
        .surface = &off_output_surface,
        .feedbacks = off_output_feedbacks,
    });
    off_output_feedbacks_owned = false;

    server.submitPendingPresentation();
    try std.testing.expectEqual(@as(usize, 1), lower_counter.discarded_count);
    try std.testing.expectEqual(@as(usize, 0), upper_counter.discarded_count);
    try std.testing.expectEqual(@as(usize, 1), off_output_counter.discarded_count);
    try std.testing.expectEqual(@as(usize, 1), server.presentation_submitted.items.len);

    var submitted = server.presentation_submitted.pop().?;
    submitted.presented(&server, .{
        .timestamp = .{ .seconds = 0, .nanoseconds = 0 },
        .refresh_nanoseconds = presentation.nominal_refresh_nanoseconds,
    });
    submitted.deinit();
    try std.testing.expectEqual(@as(usize, 1), upper_counter.presented_count);
    try std.testing.expectEqual(@as(usize, 0), upper_counter.discarded_count);
    try std.testing.expectEqual(@as(usize, 0), off_output_counter.presented_count);
}

test "native immediate repaint uses the next timer tick" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const native = try NativeServer.create(std.testing.allocator, std.testing.io, .{
        .runtime_directory = path_buffer[0..path_length],
        .output_size = .{ .width = 8, .height = 4 },
    });
    defer native.destroy();

    try std.testing.expect(native.inputRoutingAvailable());
    native.scheduleRepaint(0);
    try std.testing.expect(!native.event_loop.stop_requested);
    try std.testing.expect(native.repaint_timer.heap_index != null);
}

test "native XDG activation raises and focuses only proven mapped toplevels" {
    const core = @import("wayring-core");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const native = try NativeServer.create(std.testing.allocator, std.testing.io, .{
        .runtime_directory = path_buffer[0..path_length],
        .output_size = .{ .width = 8, .height = 4 },
    });
    defer native.destroy();

    const client = try native.server.createClient();
    var client_owned = true;
    defer if (client_owned) native.server.destroyClient(client) catch unreachable;
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
    try testTransferToNative(&peer, client);
    try testTransferFromNative(&peer, client);
    var compositor_name: u32 = 0;
    var shell_name: u32 = 0;
    var seat_name: u32 = 0;
    var activation_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_compositor.name))
            compositor_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.xdg_wm_base.name))
            shell_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.wl_seat.name))
            seat_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.xdg_activation_v1.name))
            activation_name = global.name;
    }
    const compositor: wayring.ObjectHandle = .{
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
    const shell: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            shell_name,
            generated.xdg_wm_base.name,
            6,
            4,
            &generated.xdg_wm_base,
        ),
    };
    const seat: wayring.ObjectHandle = .{
        .id = 5,
        .generation = try core.bind(
            &peer,
            registry.id,
            seat_name,
            generated.wl_seat.name,
            10,
            5,
            &generated.wl_seat,
        ),
    };
    const activation: wayring.ObjectHandle = .{
        .id = 6,
        .generation = try core.bind(
            &peer,
            registry.id,
            activation_name,
            generated.xdg_activation_v1.name,
            1,
            6,
            &generated.xdg_activation_v1,
        ),
    };
    try testTransferToNative(&peer, client);
    try native.seat_global.setPhysicalCapabilities(SeatGlobal.Capability.keyboard);
    const keyboard = try generated.wl_seat_types.requests.get_keyboard(&peer, seat);
    try testTransferToNative(&peer, client);

    const first_surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor,
    );
    const first_xdg = try generated.xdg_wm_base_types.requests.get_xdg_surface(
        &peer,
        shell,
        first_surface,
    );
    const first_toplevel = try generated.xdg_surface_types.requests.get_toplevel(
        &peer,
        first_xdg,
    );
    try generated.wl_surface_types.requests.commit(&peer, first_surface);
    const second_surface = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor,
    );
    const second_xdg = try generated.xdg_wm_base_types.requests.get_xdg_surface(
        &peer,
        shell,
        second_surface,
    );
    const second_toplevel = try generated.xdg_surface_types.requests.get_toplevel(
        &peer,
        second_xdg,
    );
    try generated.wl_surface_types.requests.commit(&peer, second_surface);
    try testTransferToNative(&peer, client);
    try testConfigureNextToplevel(native);
    try testConfigureNextToplevel(native);
    try testTransferFromNative(&peer, client);
    var first_serial: ?u32 = null;
    var second_serial: ?u32 = null;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == first_toplevel.id) {
            _ = try generated.xdg_toplevel_types.decodeEvent(&peer, first_toplevel, &message);
        } else if (message.object_id == second_toplevel.id) {
            _ = try generated.xdg_toplevel_types.decodeEvent(&peer, second_toplevel, &message);
        } else if (message.object_id == first_xdg.id) {
            first_serial = (try generated.xdg_surface_types.decodeEvent(
                &peer,
                first_xdg,
                &message,
            )).configure.serial;
        } else if (message.object_id == second_xdg.id) {
            second_serial = (try generated.xdg_surface_types.decodeEvent(
                &peer,
                second_xdg,
                &message,
            )).configure.serial;
        }
    }
    try generated.xdg_surface_types.requests.ack_configure(
        &peer,
        first_xdg,
        first_serial orelse return error.MissingFirstConfigure,
    );
    try generated.xdg_surface_types.requests.ack_configure(
        &peer,
        second_xdg,
        second_serial orelse return error.MissingSecondConfigure,
    );
    try testTransferToNative(&peer, client);

    const first = try testNativeSurface(client, first_surface.id);
    const second = try testNativeSurface(client, second_surface.id);
    const first_state = try native.stateFor(first);
    const second_state = try native.stateFor(second);
    const first_node = try native.surface_tree.nodeFor(first);
    const second_node = try native.surface_tree.nodeFor(second);
    first_node.current_active = true;
    second_node.current_active = true;
    _ = try native.xdg_shell.applied(first, true);
    _ = try native.xdg_shell.applied(second, true);
    try native.refreshKeyboardCapability(&native.seat_global);
    try std.testing.expectEqual(second, native.seat_global.keyboardFocus().?);
    try std.testing.expectEqual(first_state, native.surfaces.items[0]);
    try std.testing.expectEqual(second_state, native.surfaces.items[1]);
    try testTransferFromNative(&peer, client);
    var focus_serial: ?u32 = null;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != keyboard.id) continue;
        switch (try generated.wl_keyboard_types.decodeEvent(&peer, keyboard, &message)) {
            .enter => |enter| focus_serial = enter.serial,
            else => {},
        }
    }
    const proven_serial = focus_serial orelse return error.MissingActivationFocusSerial;

    native.repaint_needed = false;
    const unproven_resource = try generated.xdg_activation_v1_types.requests.get_activation_token(
        &peer,
        activation,
    );
    try generated.xdg_activation_token_v1_types.requests.commit(&peer, unproven_resource);
    try testTransferToNative(&peer, client);
    const unproven_token = try testReceiveActivationToken(&peer, client, unproven_resource);
    try generated.xdg_activation_v1_types.requests.activate(
        &peer,
        activation,
        &unproven_token,
        first_surface,
    );
    try testTransferToNative(&peer, client);
    try std.testing.expectEqual(second, native.seat_global.keyboardFocus().?);
    try std.testing.expectEqual(first_state, native.surfaces.items[0]);
    try std.testing.expect(!native.repaint_needed);
    try testTransferFromNative(&peer, client);
    try std.testing.expect(peer.popMessage() == null);

    const proven_resource = try generated.xdg_activation_v1_types.requests.get_activation_token(
        &peer,
        activation,
    );
    try generated.xdg_activation_token_v1_types.requests.set_serial(
        &peer,
        proven_resource,
        proven_serial,
        seat,
    );
    try generated.xdg_activation_token_v1_types.requests.set_surface(
        &peer,
        proven_resource,
        second_surface,
    );
    try generated.xdg_activation_token_v1_types.requests.commit(&peer, proven_resource);
    try testTransferToNative(&peer, client);
    const proven_token = try testReceiveActivationToken(&peer, client, proven_resource);
    try generated.xdg_activation_v1_types.requests.activate(
        &peer,
        activation,
        &proven_token,
        first_surface,
    );
    try testTransferToNative(&peer, client);
    try std.testing.expectEqual(first, native.seat_global.keyboardFocus().?);
    try std.testing.expectEqual(second_state, native.surfaces.items[0]);
    try std.testing.expectEqual(first_state, native.surfaces.items[1]);
    try std.testing.expect(native.repaint_needed);
    try testTransferFromNative(&peer, client);
    var first_activated = false;
    var second_deactivated = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == first_toplevel.id) switch (try generated.xdg_toplevel_types.decodeEvent(
            &peer,
            first_toplevel,
            &message,
        )) {
            .configure => |configure| first_activated = testConfigureActivated(configure.states),
            else => {},
        } else if (message.object_id == second_toplevel.id) switch (try generated.xdg_toplevel_types.decodeEvent(
            &peer,
            second_toplevel,
            &message,
        )) {
            .configure => |configure| second_deactivated = configure.states.len == 0,
            else => {},
        };
    }
    try std.testing.expect(first_activated and second_deactivated);

    second_node.current_active = false;
    native.repaint_needed = false;
    try xdgActivationRequested(native, second, true);
    try std.testing.expectEqual(first, native.seat_global.keyboardFocus().?);
    try std.testing.expectEqual(first_state, native.surfaces.items[1]);
    try std.testing.expect(!native.repaint_needed);
    second_node.current_active = true;
    try std.testing.expect(try native.xdg_shell.applied(second, true));
    try native.activateToplevel(second);
    try std.testing.expect(!try native.xdg_shell.applied(second, true));
    try std.testing.expectEqual(second, native.seat_global.keyboardFocus().?);
    try std.testing.expectEqual(second_state, native.surfaces.items[1]);

    // An exclusive layer epoch restores the desktop it displaced, even if a
    // different desktop was raised while the layer retained keyboard focus.
    try native.activateToplevel(first);
    try first.reference();
    native.exclusive_focus_active = true;
    native.exclusive_focus_restore = first;
    try std.testing.expect(native.raiseRoot(second));
    _ = try native.seat_global.keyboardEnter(second, &.{});
    try native.refreshKeyboardFocus(null);
    try std.testing.expectEqual(first, native.seat_global.keyboardFocus().?);
    try std.testing.expect(!native.exclusive_focus_active);
    try std.testing.expect(native.exclusive_focus_restore == null);
    _ = try native.seat_global.keyboardEnter(second, &.{});
    native.xdg_shell.setActivatedSurface(second);

    try testDrainNativePeer(&peer, client);
    try generated.wl_surface_types.requests.attach(&peer, first_surface, null, 0, 0);
    try generated.wl_surface_types.requests.commit(&peer, first_surface);
    try testTransferToNative(&peer, client);
    native.xdg_shell.setActivatedSurface(first);
    var unmap = native.compositor_global.popTransaction() orelse
        return error.MissingUnmapCommit;
    defer {
        unmap.releaseBuffers();
        unmap.deinit();
    }
    const unmap_result = try native.xdg_shell.handleCommit(&unmap.entries[0]);
    var unmap_update = unmap_result.direct_update orelse
        return error.MissingUnmapUpdate;
    try std.testing.expect(unmap_update.isCurrent());
    unmap_update.apply();
    try std.testing.expect(!try native.xdg_shell.applied(first, false));
    try testTransferFromNative(&peer, client);
    var first_state_count: usize = 0;
    var first_configure_states: [2]bool = undefined;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != first_toplevel.id) continue;
        switch (try generated.xdg_toplevel_types.decodeEvent(
            &peer,
            first_toplevel,
            &message,
        )) {
            .configure => |configure| {
                if (first_state_count < first_configure_states.len)
                    first_configure_states[first_state_count] = testConfigureActivated(
                        configure.states,
                    );
                first_state_count += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), first_state_count);
    try std.testing.expect(first_configure_states[0]);
    try std.testing.expect(!first_configure_states[1]);

    try xdgActivationRequested(native, first, true);
    try std.testing.expect(!try native.xdg_shell.applied(first, false));
    first_node.current_active = true;
    try std.testing.expect(!try native.xdg_shell.applied(first, true));

    const disposable_handle = try generated.wl_compositor_types.requests.create_surface(
        &peer,
        compositor,
    );
    try testTransferToNative(&peer, client);
    const disposable = try testNativeSurface(client, disposable_handle.id);
    const disposable_state = try native.stateFor(disposable);
    _ = native.surfaces.orderedRemove(2);
    native.surfaces.insertAssumeCapacity(1, disposable_state);
    try generated.wl_surface_types.requests.destroy(&peer, disposable_handle);
    try testTransferToNative(&peer, client);
    try std.testing.expect(native.pruneSurfaces());
    try std.testing.expectEqual(first_state, native.surfaces.items[0]);
    try std.testing.expectEqual(second_state, native.surfaces.items[1]);

    try testDrainNativePeer(&peer, client);
    try generated.xdg_toplevel_types.requests.destroy(&peer, second_toplevel);
    try testTransferToNative(&peer, client);
    try afterPlatform(native, &native.event_loop);
    try std.testing.expectEqual(first, native.seat_global.keyboardFocus().?);
    try testTransferFromNative(&peer, client);
    var left_destroyed_role = false;
    var entered_remaining_toplevel = false;
    var remaining_toplevel_activated = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id == keyboard.id) switch (try generated.wl_keyboard_types.decodeEvent(
            &peer,
            keyboard,
            &message,
        )) {
            .leave => |leave| left_destroyed_role = leave.surface == second_surface.id,
            .enter => |enter| entered_remaining_toplevel = enter.surface == first_surface.id,
            else => {},
        } else if (message.object_id == first_toplevel.id) switch (try generated.xdg_toplevel_types.decodeEvent(
            &peer,
            first_toplevel,
            &message,
        )) {
            .configure => |configure| remaining_toplevel_activated = testConfigureActivated(
                configure.states,
            ),
            else => {},
        };
    }
    try std.testing.expect(left_destroyed_role);
    try std.testing.expect(entered_remaining_toplevel);
    try std.testing.expect(remaining_toplevel_activated);

    try native.server.destroyClient(client);
    client_owned = false;
}

test "native wlr screencopy streams whole-output SHM damage frames" {
    const core = @import("wayring-core");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const native = try NativeServer.create(std.testing.allocator, std.testing.io, .{
        .runtime_directory = path_buffer[0..path_length],
        .output_size = .{ .width = 2, .height = 2 },
    });
    defer native.destroy();

    const client = try native.server.createClient();
    var client_owned = true;
    defer if (client_owned) native.server.destroyClient(client) catch unreachable;
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
    try testTransferToNative(&peer, client);
    try testTransferFromNative(&peer, client);
    var shm_name: u32 = 0;
    var output_name: u32 = 0;
    var screencopy_name: u32 = 0;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        const global = (try core.decodeRegistryEvent(&message, registry.id)).global;
        if (std.mem.eql(u8, global.interface, generated.wl_shm.name)) shm_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.wl_output.name)) output_name = global.name;
        if (std.mem.eql(u8, global.interface, generated.zwlr_screencopy_manager_v1.name))
            screencopy_name = global.name;
    }
    try std.testing.expect(shm_name != 0 and output_name != 0 and screencopy_name != 0);
    const shm_resource: wayring.ObjectHandle = .{
        .id = 3,
        .generation = try core.bind(
            &peer,
            registry.id,
            shm_name,
            generated.wl_shm.name,
            2,
            3,
            &generated.wl_shm,
        ),
    };
    const output_resource: wayring.ObjectHandle = .{
        .id = 4,
        .generation = try core.bind(
            &peer,
            registry.id,
            output_name,
            generated.wl_output.name,
            4,
            4,
            &generated.wl_output,
        ),
    };
    const screencopy_manager: wayring.ObjectHandle = .{
        .id = 5,
        .generation = try core.bind(
            &peer,
            registry.id,
            screencopy_name,
            generated.zwlr_screencopy_manager_v1.name,
            3,
            5,
            &generated.zwlr_screencopy_manager_v1,
        ),
    };
    try testTransferToNative(&peer, client);
    try testDrainNativePeer(&peer, client);

    const fd = try std.posix.memfd_create("keywork-screencopy-test", linux.MFD.CLOEXEC);
    var fd_owned = true;
    defer {
        if (fd_owned) _ = linux.close(fd);
    }
    if (linux.errno(linux.ftruncate(fd, 16)) != .SUCCESS) return error.TruncateFailed;
    const duplicate_result = linux.dup(fd);
    if (linux.errno(duplicate_result) != .SUCCESS) return error.DuplicateFailed;
    const inspect_fd: i32 = @intCast(duplicate_result);
    defer _ = linux.close(inspect_fd);
    const pool = try generated.wl_shm_types.requests.create_pool(
        &peer,
        shm_resource,
        fd,
        16,
    );
    fd_owned = false;
    const buffer = try generated.wl_shm_pool_types.requests.create_buffer(
        &peer,
        pool,
        0,
        2,
        2,
        8,
        @intFromEnum(shm.Format.argb8888),
    );
    try generated.wl_shm_pool_types.requests.destroy(&peer, pool);
    try testTransferToNative(&peer, client);
    try testDrainNativePeer(&peer, client);

    const first_frame = try generated.zwlr_screencopy_manager_v1_types.requests.capture_output(
        &peer,
        screencopy_manager,
        0,
        output_resource,
    );
    try testTransferToNative(&peer, client);
    try testTransferFromNative(&peer, client);
    var saw_buffer = false;
    var saw_buffer_done = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != first_frame.id) continue;
        switch (try generated.zwlr_screencopy_frame_v1_types.decodeEvent(
            &peer,
            first_frame,
            &message,
        )) {
            .buffer => |event| {
                try std.testing.expectEqual(@intFromEnum(shm.Format.argb8888), event.format);
                try std.testing.expectEqual(@as(u32, 2), event.width);
                try std.testing.expectEqual(@as(u32, 2), event.height);
                try std.testing.expectEqual(@as(u32, 8), event.stride);
                saw_buffer = true;
            },
            .buffer_done => saw_buffer_done = true,
            else => return error.UnexpectedScreencopyConstraintEvent,
        }
    }
    try std.testing.expect(saw_buffer and saw_buffer_done);
    try generated.zwlr_screencopy_frame_v1_types.requests.copy(
        &peer,
        first_frame,
        buffer,
    );
    try testTransferToNative(&peer, client);
    try afterPlatform(native, &native.event_loop);
    try std.testing.expect(native.screencopy_global.hasPendingIo());
    try testDrainScreencopy(native);
    try testTransferFromNative(&peer, client);
    var first_flags = false;
    var first_ready = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != first_frame.id) continue;
        switch (try generated.zwlr_screencopy_frame_v1_types.decodeEvent(
            &peer,
            first_frame,
            &message,
        )) {
            .flags => |event| {
                try std.testing.expectEqual(@as(u32, 0), event.flags);
                first_flags = true;
            },
            .ready => first_ready = true,
            else => return error.UnexpectedScreencopyReadyEvent,
        }
    }
    try std.testing.expect(first_flags and first_ready);
    var captured: [4]u32 = undefined;
    const read_result = linux.pread(
        inspect_fd,
        std.mem.asBytes(&captured).ptr,
        @sizeOf(@TypeOf(captured)),
        0,
    );
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(read_result));
    try std.testing.expectEqual(@as(usize, @sizeOf(@TypeOf(captured))), read_result);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, &captured);

    try generated.zwlr_screencopy_frame_v1_types.requests.destroy(&peer, first_frame);
    const second_frame = try generated.zwlr_screencopy_manager_v1_types.requests.capture_output(
        &peer,
        screencopy_manager,
        0,
        output_resource,
    );
    try testTransferToNative(&peer, client);
    try testDrainNativePeer(&peer, client);
    try generated.zwlr_screencopy_frame_v1_types.requests.copy_with_damage(
        &peer,
        second_frame,
        buffer,
    );
    try testTransferToNative(&peer, client);
    try afterPlatform(native, &native.event_loop);
    try testTransferFromNative(&peer, client);
    try std.testing.expect(peer.popMessage() == null);

    native.scheduleRepaint(0);
    try afterPlatform(native, &native.event_loop);
    try testDrainScreencopy(native);
    try testTransferFromNative(&peer, client);
    var second_flags = false;
    var second_damage = false;
    var second_ready = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != second_frame.id) continue;
        switch (try generated.zwlr_screencopy_frame_v1_types.decodeEvent(
            &peer,
            second_frame,
            &message,
        )) {
            .flags => |event| {
                try std.testing.expectEqual(@as(u32, 0), event.flags);
                second_flags = true;
            },
            .damage => |event| {
                try std.testing.expectEqual(@as(u32, 0), event.x);
                try std.testing.expectEqual(@as(u32, 0), event.y);
                try std.testing.expectEqual(@as(u32, 2), event.width);
                try std.testing.expectEqual(@as(u32, 2), event.height);
                second_damage = true;
            },
            .ready => second_ready = true,
            else => return error.UnexpectedScreencopyDamageEvent,
        }
    }
    try std.testing.expect(second_flags and second_damage and second_ready);

    const failed_frame = try generated.zwlr_screencopy_manager_v1_types.requests.capture_output(
        &peer,
        screencopy_manager,
        0,
        output_resource,
    );
    const queued_frame = try generated.zwlr_screencopy_manager_v1_types.requests.capture_output(
        &peer,
        screencopy_manager,
        0,
        output_resource,
    );
    try testTransferToNative(&peer, client);
    try testDrainNativePeer(&peer, client);
    try generated.zwlr_screencopy_frame_v1_types.requests.copy(
        &peer,
        failed_frame,
        buffer,
    );
    try generated.zwlr_screencopy_frame_v1_types.requests.copy(
        &peer,
        queued_frame,
        buffer,
    );
    try testTransferToNative(&peer, client);
    native.screencopy_global.listener.capture = failTestScreencopyCapture;
    try afterPlatform(native, &native.event_loop);
    try std.testing.expect(native.repaint_needed);
    try testTransferFromNative(&peer, client);
    var first_failed = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != failed_frame.id) continue;
        switch (try generated.zwlr_screencopy_frame_v1_types.decodeEvent(
            &peer,
            failed_frame,
            &message,
        )) {
            .failed => first_failed = true,
            else => return error.UnexpectedScreencopyFailureEvent,
        }
    }
    try std.testing.expect(first_failed);

    native.screencopy_global.listener.capture = captureScreencopy;
    try afterPlatform(native, &native.event_loop);
    try std.testing.expect(native.screencopy_global.hasPendingIo());
    try testDrainScreencopy(native);
    try testTransferFromNative(&peer, client);
    var queued_ready = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != queued_frame.id) continue;
        switch (try generated.zwlr_screencopy_frame_v1_types.decodeEvent(
            &peer,
            queued_frame,
            &message,
        )) {
            .flags => {},
            .ready => queued_ready = true,
            else => return error.UnexpectedQueuedScreencopyEvent,
        }
    }
    try std.testing.expect(queued_ready);

    const canceled_frame = try generated.zwlr_screencopy_manager_v1_types.requests.capture_output(
        &peer,
        screencopy_manager,
        0,
        output_resource,
    );
    try testTransferToNative(&peer, client);
    try testDrainNativePeer(&peer, client);
    try generated.zwlr_screencopy_frame_v1_types.requests.copy(
        &peer,
        canceled_frame,
        buffer,
    );
    try testTransferToNative(&peer, client);
    try afterPlatform(native, &native.event_loop);
    try std.testing.expect(native.screencopy_global.hasPendingIo());
    try native.server.destroyClient(client);
    client_owned = false;
    try testDrainScreencopy(native);
    try std.testing.expect(!native.screencopy_global.hasPendingIo());
}

test "native compositor owns and drains its io_uring listener" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const native = try NativeServer.create(std.testing.allocator, std.testing.io, .{
        .runtime_directory = path_buffer[0..path_length],
        .output_size = .{ .width = 8, .height = 4 },
    });
    defer native.destroy();

    try std.testing.expect(std.mem.startsWith(u8, native.displayName(), "wayland-"));
    const stop_timer = try native.event_loop.addTimer(native, stopTestServer);
    defer native.event_loop.removeTimer(stop_timer);
    try stop_timer.arm(1, 0);
    try native.run();
    try std.testing.expectEqual(@as(u64, 0), native.inspectFrame().frame_count);
    try std.testing.expectEqual(@as(u32, 0), native.pixel(7, 3));
}

fn stopTestServer(context: *anyopaque, _: *EventLoop, _: u64) !void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    self.terminate();
}

fn testConfigureNextToplevel(native: *NativeServer) !void {
    var transaction = native.compositor_global.popTransaction() orelse
        return error.MissingToplevelCommit;
    defer {
        transaction.releaseBuffers();
        transaction.deinit();
    }
    if (transaction.entries.len != 1) return error.UnexpectedToplevelTransaction;
    try std.testing.expectEqual(
        .configure_only,
        (try native.xdg_shell.handleCommit(&transaction.entries[0])).disposition,
    );
}

fn testNativeSurface(
    client: *Server.Client,
    id: u32,
) !*CompositorGlobal.Surface {
    const object = client.connection.object(id) orelse return error.MissingNativeSurface;
    return CompositorGlobal.surfaceFor(client, .{ .id = id, .generation = object.generation });
}

fn testConfigureActivated(states: []const u8) bool {
    if (states.len != @sizeOf(u32)) return false;
    const activated: u32 = @intFromEnum(generated.xdg_toplevel_types.state.activated);
    return std.mem.eql(u8, states, std.mem.asBytes(&activated));
}

fn testReceiveActivationToken(
    peer: *wayring.Connection,
    client: *Server.Client,
    resource: wayring.ObjectHandle,
) ![32]u8 {
    try testTransferFromNative(peer, client);
    var token: [32]u8 = undefined;
    var found = false;
    while (peer.popMessage()) |popped| {
        var message = popped;
        defer message.deinit();
        if (message.object_id != resource.id) continue;
        const event = try generated.xdg_activation_token_v1_types.decodeEvent(
            peer,
            resource,
            &message,
        );
        if (event.done.token.len != token.len) return error.UnexpectedActivationTokenLength;
        @memcpy(&token, event.done.token);
        found = true;
    }
    if (!found) return error.MissingActivationToken;
    return token;
}

fn testDrainNativePeer(
    peer: *wayring.Connection,
    client: *Server.Client,
) !void {
    try testTransferFromNative(peer, client);
    while (peer.popMessage()) |popped| {
        var message = popped;
        message.deinit();
    }
}

fn testDrainScreencopy(native: *NativeServer) !void {
    var attempts: usize = 0;
    while (native.screencopy_global.hasPendingIo()) : (attempts += 1) {
        if (attempts == 8) return error.ScreencopyDidNotComplete;
        try native.event_loop.ioLoop().runOnce();
    }
}

fn failTestScreencopyCapture(
    _: *anyopaque,
    _: []const render.Command,
    _: render.Scale,
    _: render.PixelBuffer,
) !?std.posix.fd_t {
    return error.TestCaptureFailure;
}

fn testTransferToNative(
    connection: *wayring.Connection,
    client: *Server.Client,
) !void {
    while (connection.nextBatch()) |batch| {
        var duplicated: [wayring.max_fds_per_batch]i32 = undefined;
        var count: usize = 0;
        errdefer {
            for (duplicated[0..count]) |fd| _ = linux.close(fd);
        }
        for (batch.fds) |fd| {
            const result = linux.dup(fd);
            if (linux.errno(result) != .SUCCESS) return error.DuplicateFdFailed;
            duplicated[count] = @intCast(result);
            count += 1;
        }
        const received_fds = duplicated[0..count];
        count = 0;
        try client.receive(batch.bytes, received_fds);
        try connection.acknowledge(batch.token, batch.bytes.len);
    }
}

fn testTransferFromNative(
    connection: *wayring.Connection,
    client: *Server.Client,
) !void {
    while (client.connection.nextBatch()) |batch| {
        try connection.feed(batch.bytes, batch.fds);
        try client.connection.acknowledge(batch.token, batch.bytes.len);
    }
    try client.outputDrained();
}
