//! Wayland display and compositor-global lifetime.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const slot_map = @import("slot_map.zig");
const presentation = @import("presentation.zig");
const Compositor = @import("wayland/compositor.zig");
const Subcompositor = @import("wayland/subcompositor.zig");
const XdgOutput = @import("wayland/xdg_output.zig");
const XdgShell = @import("wayland/xdg_shell.zig");
const GtkShell = @import("wayland/gtk_shell.zig");
const XdgForeign = @import("wayland/xdg_foreign.zig");
const LayerShell = @import("wayland/layer_shell.zig");
const SinglePixelBuffer = @import("wayland/single_pixel_buffer.zig");
const ContentType = @import("wayland/content_type.zig");
const ColorManagement = @import("wayland/color_management.zig");
const ColorRepresentation = @import("wayland/color_representation.zig");
const AlphaModifier = @import("wayland/alpha_modifier.zig");
const BackgroundEffect = @import("wayland/background_effect.zig");
const SecurityContext = @import("wayland/security_context.zig");
const SessionLock = @import("wayland/session_lock.zig");
const CursorShape = @import("wayland/cursor_shape.zig");
const Tablet = @import("wayland/tablet.zig");
const RelativePointer = @import("wayland/relative_pointer.zig");
const PointerGestures = @import("wayland/pointer_gestures.zig");
const PointerConstraints = @import("wayland/pointer_constraints.zig");
const PointerWarp = @import("wayland/pointer_warp.zig");
const IdleInhibit = @import("wayland/idle_inhibit.zig");
const KeyboardShortcutsInhibit = @import("wayland/keyboard_shortcuts_inhibit.zig");
const IdleNotify = @import("wayland/idle_notify.zig");
const Seat = @import("wayland/seat.zig");
const DataDevice = @import("wayland/data_device.zig");
const XdgToplevelDrag = @import("wayland/xdg_toplevel_drag.zig");
const XdgToplevelIcon = @import("wayland/xdg_toplevel_icon.zig");
const XdgDialog = @import("wayland/xdg_dialog.zig");
const XdgSystemBell = @import("wayland/xdg_system_bell.zig");
const XdgToplevelTag = @import("wayland/xdg_toplevel_tag.zig");
const XdgSessionManagement = @import("wayland/xdg_session_management.zig");
const TransientSeat = @import("wayland/transient_seat.zig");
const PrimarySelection = @import("wayland/primary_selection.zig");
const DataControl = @import("wayland/data_control.zig");
const ForeignToplevelList = @import("wayland/foreign_toplevel_list.zig");
const ImageCaptureSource = @import("wayland/image_capture_source.zig");
const ImageCopyCapture = @import("wayland/image_copy_capture.zig");
const Screencopy = @import("wayland/screencopy.zig");
const XwaylandKeyboardGrab = @import("wayland/xwayland_keyboard_grab.zig");
const XwaylandShell = @import("wayland/xwayland_shell.zig");
const XwaylandServer = @import("xwayland/server.zig");
const Xwm = @import("xwayland/xwm.zig");
const Workspace = @import("wayland/workspace.zig");
const TextInput = @import("wayland/text_input.zig");
const InputMethod = @import("wayland/input_method.zig");
const VirtualKeyboard = @import("wayland/virtual_keyboard.zig");
const VirtualPointer = @import("wayland/virtual_pointer.zig");
const PresentationProtocol = @import("wayland/presentation.zig");
const FractionalScale = @import("wayland/fractional_scale.zig");
const Fixes = @import("wayland/fixes.zig");
const LinuxDmabuf = @import("wayland/linux_dmabuf.zig");
const LinuxDrmSyncobj = @import("wayland/linux_drm_syncobj.zig");
const TearingControl = @import("wayland/tearing_control.zig");
const Fifo = @import("wayland/fifo.zig");
const CommitTiming = @import("wayland/commit_timing.zig");
const XdgActivation = @import("wayland/xdg_activation.zig");
const Output = @import("wayland/output.zig");
const OutputLayout = @import("wayland/output_layout.zig");
const OutputManagement = @import("wayland/output_management.zig");
const OutputPower = @import("wayland/output_power.zig");
const GammaControl = @import("wayland/gamma_control.zig");
const DrmLease = @import("wayland/drm_lease.zig");
const OutputBackend = @import("backend/output.zig");
const DrmDevice = @import("backend/drm_device.zig");
const DrmOutput = @import("backend/drm.zig");
const NativeInput = @import("backend/native_input.zig");
const Session = @import("backend/session.zig");
const Icc = @import("render/icc.zig");
const Renderer = @import("render/Renderer.zig");
const render = @import("render/types.zig");
const FrameStatistics = @import("FrameStatistics.zig");
const Region = @import("region.zig");
const Scene = @import("scene.zig");
const Surface = @import("wayland/surface.zig");
const Viewporter = @import("wayland/viewporter.zig");
const InputManager = @import("input_manager.zig");
const BuiltinKeybindings = @import("builtin_keybindings.zig");
const Command = @import("command.zig").Command;
const Config = @import("config.zig");
const AppearanceClient = @import("AppearanceClient.zig");
const theme = @import("theme.zig");
const input_configuration = @import("input_configuration.zig");
const output_configuration = @import("output_configuration.zig");
const Launcher = @import("launcher.zig");
const Logging = @import("logging.zig");
const Control = @import("control.zig");
const ControlProtocol = @import("keywork-control");
const WindowManager = @import("window_manager.zig");
const WindowAnimation = @import("window_animation.zig");
const backdrop_blur_damage = @import("backdrop_blur_damage.zig");
const capture_geometry = @import("capture_geometry.zig");
const damage_geometry = @import("damage_geometry.zig");
const window_geometry = @import("window_geometry.zig");

const c = @cImport({
    @cInclude("linux/sync_file.h");
    @cInclude("sys/ioctl.h");
});
const wl = wayland.server.wl;
const log = std.log.scoped(.server);

fn logProtocolError(
    _: *wl.Server,
    direction: wl.ProtocolLogger.Type,
    message: *const wl.ProtocolLogger.LogMessage,
) void {
    if (direction != .event or
        !std.mem.eql(u8, std.mem.span(message.resource.getClass()), "wl_display") or
        !std.mem.eql(u8, std.mem.span(message.message.name), "error") or
        message.arguments_count < 3)
    {
        return;
    }
    const arguments = message.arguments orelse return;
    const credentials = message.resource.getClient().getCredentials();
    const description = arguments[2].s orelse "unknown protocol error";
    const object: ?*wl.Resource = @ptrCast(arguments[0].o);
    if (object) |resource| {
        log.err("Wayland protocol error for pid {d}: {s}@{d} code {d}: {s}", .{
            credentials.pid,
            resource.getClass(),
            resource.getId(),
            arguments[1].u,
            description,
        });
    } else {
        log.err("Wayland protocol error for pid {d}: unknown object code {d}: {s}", .{
            credentials.pid,
            arguments[1].u,
            description,
        });
    }
}
const linux_button_left = 0x110;

allocator: std.mem.Allocator,
io: std.Io,
display: *wl.Server,
control: Control,
control_initialized: bool,
appearance_client: AppearanceClient,
appearance_client_initialized: bool,
configuration: ?Config.Store,
palette: theme.Palette,
reduced_motion: bool,
session: Session,
session_initialized: bool,
drm_device: DrmDevice,
drm_device_initialized: bool,
native_input: NativeInput,
native_input_initialized: bool,
input_manager: InputManager,
input_manager_initialized: bool,
builtin_keybindings: BuiltinKeybindings,
builtin_keybindings_initialized: bool,
render_outputs: RenderOutputStore,
primary_render_output: RenderOutputId,
outputs: OutputLayout,
xdg_output: XdgOutput,
xdg_output_initialized: bool,
output_management: OutputManagement,
output_management_initialized: bool,
output_power: OutputPower,
output_power_initialized: bool,
gamma_control: GammaControl,
gamma_control_initialized: bool,
drm_lease: DrmLease,
drm_lease_initialized: bool,
single_pixel_buffer: SinglePixelBuffer,
content_type: ContentType,
color_management: ColorManagement,
color_representation: ColorRepresentation,
alpha_modifier: AlphaModifier,
background_effect: BackgroundEffect,
security_context: SecurityContext,
session_lock: SessionLock,
session_lock_initialized: bool,
cursor_shape: CursorShape,
tablet: Tablet,
relative_pointer: RelativePointer,
pointer_gestures: PointerGestures,
pointer_constraints: PointerConstraints,
pointer_warp: PointerWarp,
idle_inhibit: IdleInhibit,
keyboard_shortcuts_inhibit: KeyboardShortcutsInhibit,
idle_notify: IdleNotify,
idle_notify_initialized: bool,
compositor: Compositor,
subcompositor: Subcompositor,
scene: Scene,
xdg_shell: XdgShell,
gtk_shell: GtkShell,
xdg_foreign: XdgForeign,
layer_shell: LayerShell,
layer_shell_initialized: bool,
seat: Seat,
transient_seat: TransientSeat,
input_device_listener: InputManager.DeviceListener,
routed_keys: std.ArrayList(RoutedKey),
routed_buttons: std.ArrayList(RoutedButton),
routed_gestures: std.ArrayList(RoutedGesture),
routed_touches: std.ArrayList(RoutedTouch),
next_touch_id: u31,
data_device: DataDevice,
xdg_toplevel_drag: XdgToplevelDrag,
xdg_toplevel_icon: XdgToplevelIcon,
xdg_dialog: XdgDialog,
xdg_system_bell: XdgSystemBell,
xdg_toplevel_tag: XdgToplevelTag,
xdg_session_management: XdgSessionManagement,
primary_selection: PrimarySelection,
data_control: DataControl,
foreign_toplevel_list: ForeignToplevelList,
foreign_toplevel_list_initialized: bool,
image_capture_source: ImageCaptureSource,
image_capture_source_initialized: bool,
image_copy_capture: ImageCopyCapture,
image_copy_capture_initialized: bool,
screencopy: Screencopy,
screencopy_initialized: bool,
composed_capture_source: ?ComposedCaptureSource,
xwayland_keyboard_grab: XwaylandKeyboardGrab,
xwayland_keyboard_grab_initialized: bool,
xwayland_shell: XwaylandShell,
xwayland_shell_initialized: bool,
xwayland_server: XwaylandServer,
xwayland_server_initialized: bool,
xwm: Xwm,
xwm_initialized: bool,
xwayland_windows: std.AutoHashMapUnmanaged(Xwm.WindowId, XwaylandWindow),
xwayland_client_stack: std.ArrayList(Xwm.WindowId),
xwayland_override_redirect_focus: ?Surface.Id,
workspace: Workspace,
workspace_initialized: bool,
text_input: TextInput,
input_method: InputMethod,
virtual_keyboard: VirtualKeyboard,
virtual_pointer: VirtualPointer,
presentation_protocol: PresentationProtocol,
fractional_scale: FractionalScale,
fixes: Fixes,
linux_dmabuf: LinuxDmabuf,
linux_drm_syncobj: LinuxDrmSyncobj,
tearing_control: TearingControl,
fifo: Fifo,
commit_timing: CommitTiming,
xdg_activation: XdgActivation,
viewporter: Viewporter,
window_manager: WindowManager,
window_manager_initialized: bool,
window_transitions: std.ArrayList(WindowTransition),
workspace_transitions: std.ArrayList(WorkspaceTransition),
animation_now: i96,
renderer: Renderer,
socket_buffer: [11]u8,
listening: bool,
xwayland_display_listener: ?XwaylandDisplayListener,

pub const XwaylandDisplayListener = struct {
    context: *anyopaque,
    available: *const fn (*anyopaque, []const u8) void,
    unavailable: *const fn (*anyopaque) void,
};

const ComposedCaptureSource = struct {
    output: OutputLayout.Id,
    target: render.Target,
    primary_cursor_painted: bool,
    tablet_cursors_painted: bool,
};

const RenderOutput = struct {
    server: *Self,
    backend: OutputBackend,
    protocol_id: OutputLayout.Id,
    color_description: render.ColorDescription,
    output_calibration: ?render.OutputCalibration,
    timer: ?*wl.EventSource,
    repaint_idle: ?*wl.EventSource,
    frame_callback_timer: ?*wl.EventSource,
    damage: Region,
    damage_rectangles: std.ArrayList(render.Rect),
    /// Surfaces whose image commands survived occlusion pruning in the last
    /// output frame. Unlike wl_output membership, this tracks pixel contribution.
    sampled_surfaces: std.ArrayList(Surface.Id),
    sampled_surfaces_valid: bool,
    repaint_needed: bool,
    render_scheduled: bool,
    frame_callback_scheduled: bool,
    lock_frame_pending: bool,
    consecutive_output_busy_retries: u8,
    frame_statistics: FrameStatistics,
    render_budget: RenderBudget,
    request_started_nanoseconds: ?i96,
    frame_callback_deadline_nanoseconds: ?i96,
    repaint_deadline_nanoseconds: ?i96,
    /// Vblank the currently scheduled delayed repaint is aiming for, set by
    /// scheduleRepaint and consumed by beginFrame. Null when the pending
    /// repaint was scheduled immediately and thus targets no deadline.
    repaint_target_vblank_nanoseconds: ?i96,
    pending_frame: ?PendingFrame,
    cursor_state: enum { software, activating, hardware, deactivating },
    cursor_transition_committed: bool,

    const Point = struct { x: f64, y: f64 };

    fn requestFrame(self: *RenderOutput) void {
        if (self.repaint_needed) return;
        self.request_started_nanoseconds = nowNanoseconds(self.server.io);
        increment(&self.frame_statistics.frames_requested);
        self.repaint_needed = true;
    }

    /// `render_start_nanoseconds` must be captured when frame production
    /// begins, before transition processing and cursor preparation, so the
    /// repaint-delay budget covers everything between the repaint timer
    /// firing and the frame being ready for the vblank.
    fn beginFrame(self: *RenderOutput, render_start_nanoseconds: i96) void {
        std.debug.assert(self.pending_frame == null);
        self.pending_frame = .{
            .request_nanoseconds = self.request_started_nanoseconds orelse
                render_start_nanoseconds,
            .render_nanoseconds = render_start_nanoseconds,
            .target_vblank_nanoseconds = self.repaint_target_vblank_nanoseconds,
        };
        self.repaint_target_vblank_nanoseconds = null;
        self.request_started_nanoseconds = null;
        increment(&self.frame_statistics.frames_started);
    }

    fn commitFrame(
        self: *RenderOutput,
        path: FramePath,
        damage: *const Region,
        scanout_format: ?render.DmabufFormat,
        render_fence_fd: ?std.posix.fd_t,
    ) void {
        const pending = if (self.pending_frame) |*frame| frame else unreachable;
        std.debug.assert(pending.commit_nanoseconds == null);
        std.debug.assert(path == .composited or scanout_format != null);
        pending.commit_nanoseconds = nowNanoseconds(self.server.io);
        pending.trackRenderFence(render_fence_fd);
        pending.path = path;
        self.consecutive_output_busy_retries = 0;
        self.frame_statistics.recordFrame(path, scanout_format, damage);
        if (self.cursor_state == .activating or self.cursor_state == .deactivating) {
            self.cursor_transition_committed = true;
        }
        switch (path) {
            .composited => increment(&self.frame_statistics.composited_frames),
            .direct_scanout => increment(&self.frame_statistics.direct_scanout_frames),
            .overlay_scanout => increment(&self.frame_statistics.overlay_scanout_frames),
        }
    }

    fn retryOutputBusy(self: *RenderOutput) bool {
        if (self.consecutive_output_busy_retries == maximum_output_busy_retries) {
            log.err(
                "output remained busy after {d} page flip retries",
                .{maximum_output_busy_retries},
            );
            return false;
        }
        self.consecutive_output_busy_retries += 1;
        return true;
    }

    fn presentFrame(self: *RenderOutput, info: presentation.Info) void {
        var pending = self.pending_frame orelse return;
        self.pending_frame = null;
        defer pending.deinit();
        const dispatched_nanoseconds = nowNanoseconds(self.server.io);
        const presented_nanoseconds = if (self.backend.presentationClockId() ==
            presentation.monotonic_clock_id)
            info.timestamp.toNanoseconds()
        else
            dispatched_nanoseconds;
        if (pending.render_fence_fd) |fd| {
            pending.render_completion_nanoseconds = syncFileSignalNanoseconds(fd);
        }
        const refresh_nanoseconds = presentationRefreshNanoseconds(
            info,
            self.backend.refreshMillihertz(),
        );
        self.recordRenderBudget(&pending, presented_nanoseconds);
        self.frame_statistics.recordPresentation(
            .{
                .request_nanoseconds = pending.request_nanoseconds,
                .render_nanoseconds = pending.render_nanoseconds,
                .commit_nanoseconds = pending.commit_nanoseconds orelse unreachable,
                .render_completion_nanoseconds = pending.render_completion_nanoseconds,
            },
            presented_nanoseconds,
            refresh_nanoseconds,
        );
    }

    /// Feeds the repaint-delay budget from a presented frame.
    fn recordRenderBudget(
        self: *RenderOutput,
        pending: *const PendingFrame,
        presented_nanoseconds: i96,
    ) void {
        const completion = pending.render_completion_nanoseconds;
        const commit = pending.commit_nanoseconds orelse unreachable;
        switch (renderBudgetUpdate(
            pending.path orelse unreachable,
            pending.render_nanoseconds,
            if (completion) |signal| @max(signal, commit) else null,
            presented_nanoseconds,
            pending.target_vblank_nanoseconds,
        )) {
            .ignore => {},
            .reset => |cause| {
                self.render_budget.reset();
                switch (cause) {
                    .missed_deadline => increment(
                        &self.frame_statistics.render_budget_resets_missed,
                    ),
                    .no_timing => increment(
                        &self.frame_statistics.render_budget_resets_no_timing,
                    ),
                }
                if (cause == .missed_deadline) {
                    const target = pending.target_vblank_nanoseconds orelse unreachable;
                    std.debug.assert(presented_nanoseconds > target);
                    const lateness: u64 = @intCast(presented_nanoseconds - target);
                    self.frame_statistics.render_budget_last_miss_nanoseconds = lateness;
                    self.frame_statistics.render_budget_maximum_miss_nanoseconds = @max(
                        self.frame_statistics.render_budget_maximum_miss_nanoseconds,
                        lateness,
                    );
                }
            },
            .sample => |duration| self.render_budget.record(duration),
        }
    }

    fn discardFrame(self: *RenderOutput) void {
        if (self.pending_frame == null) return;
        self.clearPendingFrame();
        increment(&self.frame_statistics.frames_discarded);
    }

    fn clearPendingFrame(self: *RenderOutput) void {
        if (self.pending_frame) |*pending| pending.deinit();
        self.pending_frame = null;
    }

    fn globalPoint(self: *RenderOutput, x: f64, y: f64) Point {
        const position = self.server.outputs.get(self.protocol_id).?.logicalPosition();
        return .{
            .x = x + @as(f64, @floatFromInt(position.x)),
            .y = y + @as(f64, @floatFromInt(position.y)),
        };
    }
};

const maximum_output_busy_retries = 60;
const FramePath = FrameStatistics.FramePath;

const PendingFrame = struct {
    request_nanoseconds: i96,
    render_nanoseconds: i96,
    commit_nanoseconds: ?i96 = null,
    render_fence_fd: ?std.posix.fd_t = null,
    render_completion_nanoseconds: ?i96 = null,
    path: ?FramePath = null,
    /// Predicted vblank this frame was delayed toward, or null when the
    /// repaint started immediately and had no particular deadline.
    target_vblank_nanoseconds: ?i96 = null,

    fn trackRenderFence(self: *PendingFrame, render_fence_fd: ?std.posix.fd_t) void {
        const fd = render_fence_fd orelse return;
        std.debug.assert(self.render_fence_fd == null);
        const duplicate = std.c.fcntl(
            fd,
            std.posix.F.DUPFD_CLOEXEC,
            @as(c_int, 0),
        );
        if (duplicate < 0) {
            log.warn("failed to retain render fence for presentation timing: {t}", .{
                std.posix.errno(duplicate),
            });
            return;
        }
        self.render_fence_fd = duplicate;
    }

    fn deinit(self: *PendingFrame) void {
        if (self.render_fence_fd) |fd| _ = std.c.close(fd);
        self.render_fence_fd = null;
    }
};

fn nowNanoseconds(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn syncFileSignalNanoseconds(fd: std.posix.fd_t) ?i96 {
    var info: c.sync_file_info = std.mem.zeroes(c.sync_file_info);
    if (!readSyncFileInfo(fd, &info) or info.status != 1 or info.num_fences == 0) return null;

    var fences: [16]c.sync_fence_info = undefined;
    if (info.num_fences > fences.len) return null;
    const fence_count = info.num_fences;
    info = std.mem.zeroes(c.sync_file_info);
    info.num_fences = fence_count;
    info.sync_fence_info = @intFromPtr(&fences);
    if (!readSyncFileInfo(fd, &info) or info.status != 1 or info.num_fences > fence_count) return null;

    var signal_nanoseconds: u64 = 0;
    for (fences[0..info.num_fences]) |fence| {
        if (fence.status != 1 or fence.timestamp_ns == 0) return null;
        signal_nanoseconds = @max(signal_nanoseconds, fence.timestamp_ns);
    }
    return signal_nanoseconds;
}

fn readSyncFileInfo(fd: std.posix.fd_t, info: *c.sync_file_info) bool {
    while (true) {
        const result = c.ioctl(fd, c.SYNC_IOC_FILE_INFO, info);
        if (result == 0) return true;
        if (std.posix.errno(result) != .INTR) return false;
    }
}

fn presentationRefreshNanoseconds(info: presentation.Info, refresh_millihertz: i32) u64 {
    if (info.refresh_nanoseconds != 0) return info.refresh_nanoseconds;
    return outputRefreshNanoseconds(refresh_millihertz);
}

fn outputRefreshNanoseconds(refresh_millihertz: i32) u64 {
    if (refresh_millihertz <= 0) return presentation.nominal_refresh_nanoseconds;
    const frequency: u64 = @intCast(refresh_millihertz);
    return (std.time.ns_per_s * 1000 + frequency / 2) / frequency;
}

/// Rolling worst case of recent composited render durations, from render
/// start to GPU completion. Determines how long a repaint may be delayed
/// toward the next vblank without risking a missed deadline.
const RenderBudget = struct {
    samples: [sample_capacity]u64 = undefined,
    count: usize = 0,
    next: usize = 0,

    const sample_capacity = 32;

    fn record(self: *RenderBudget, duration_nanoseconds: u64) void {
        self.samples[self.next] = duration_nanoseconds;
        self.next = (self.next + 1) % sample_capacity;
        self.count = @min(self.count + 1, sample_capacity);
    }

    fn reset(self: *RenderBudget) void {
        self.count = 0;
        self.next = 0;
    }

    /// Worst duration in the window, or null until the window is full so
    /// a few fast frames cannot understate the budget.
    fn budgetNanoseconds(self: *const RenderBudget) ?u64 {
        if (self.count < sample_capacity) return null;
        var maximum: u64 = 0;
        for (self.samples[0..self.count]) |sample| maximum = @max(maximum, sample);
        return maximum;
    }
};

/// Presentation later than the targeted vblank by more than this clears
/// the repaint-delay budget. Absorbs vblank prediction jitter between the
/// extrapolated target and the actual presentation timestamp.
const repaint_miss_tolerance_nanoseconds = std.time.ns_per_ms;

const RenderBudgetResetCause = enum { missed_deadline, no_timing };

const RenderBudgetUpdate = union(enum) {
    ignore,
    reset: RenderBudgetResetCause,
    sample: u64,
};

/// Decides how a presented frame updates the repaint-delay budget. A
/// delayed frame presented after the vblank it targeted resets the budget
/// so a stale estimate cannot keep causing misses; immediate frames have
/// no deadline the budget could have caused them to miss, so their cost
/// only feeds the sample window. Frames that render the primary plane
/// contribute a sample from render start until the frame is ready for the
/// vblank: the later of GPU completion and DRM commit. Direct scanout
/// performs no rendering and cannot sample, and a frame without a ready
/// timestamp inside the render-to-presentation interval resets the budget
/// because delays would be flying blind.
fn renderBudgetUpdate(
    path: FramePath,
    render_nanoseconds: i96,
    ready_nanoseconds: ?i96,
    presented_nanoseconds: i96,
    target_vblank_nanoseconds: ?i96,
) RenderBudgetUpdate {
    if (target_vblank_nanoseconds) |target| {
        if (presented_nanoseconds > target + repaint_miss_tolerance_nanoseconds) {
            return .{ .reset = .missed_deadline };
        }
    }
    if (path == .direct_scanout) return .ignore;
    const ready = ready_nanoseconds orelse return .{ .reset = .no_timing };
    if (ready < render_nanoseconds or ready > presented_nanoseconds) {
        return .{ .reset = .no_timing };
    }
    return .{ .sample = @intCast(ready - render_nanoseconds) };
}

/// Subtracted from the predicted vblank deadline to absorb timer
/// granularity, scheduler wakeup latency, and budget estimation error.
const repaint_delay_margin_nanoseconds = 2 * std.time.ns_per_ms;

/// Delays shorter than this are not worth a timer round-trip; rendering
/// starts immediately as before.
const minimum_repaint_delay_milliseconds = 2;

/// Milliseconds to wait before starting a repaint so that rendering
/// completes just ahead of the predicted vblank, or null when the frame
/// should start immediately.
fn repaintDelayFromDeadline(
    now_nanoseconds: i96,
    next_vblank_nanoseconds: i96,
    render_budget_nanoseconds: u64,
) ?i32 {
    const start_deadline = next_vblank_nanoseconds -
        @as(i96, render_budget_nanoseconds) - repaint_delay_margin_nanoseconds;
    if (start_deadline <= now_nanoseconds) return null;
    // Round down so rendering starts early rather than past the deadline.
    const delay = @divTrunc(start_deadline - now_nanoseconds, std.time.ns_per_ms);
    if (delay < minimum_repaint_delay_milliseconds) return null;
    return @intCast(@min(delay, std.math.maxInt(i32)));
}

const PeriodicTimerSchedule = struct {
    deadline_nanoseconds: i96,
    delay_milliseconds: i32,
};

fn periodicTimerSchedule(
    now_nanoseconds: i96,
    previous_deadline_nanoseconds: ?i96,
    interval_nanoseconds: u64,
) PeriodicTimerSchedule {
    std.debug.assert(interval_nanoseconds > 0);
    const interval: i96 = interval_nanoseconds;
    // Advance the prior target instead of adding a full interval after damage or
    // callback processing, which would make client time lower the output rate.
    var deadline = previous_deadline_nanoseconds orelse now_nanoseconds + interval;
    if (deadline <= now_nanoseconds) {
        const elapsed = now_nanoseconds - deadline;
        deadline += (@divTrunc(elapsed, interval) + 1) * interval;
    }
    const remaining = deadline - now_nanoseconds;
    const delay = @divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    return .{
        .deadline_nanoseconds = deadline,
        .delay_milliseconds = @intCast(@min(delay, std.math.maxInt(i32))),
    };
}

fn increment(value: *u64) void {
    value.* +|= 1;
}

test "periodic output timer preserves fractional refresh phase" {
    const interval = 8_333_333;
    const first = periodicTimerSchedule(0, null, interval);
    try std.testing.expectEqual(@as(i96, 8_333_333), first.deadline_nanoseconds);
    try std.testing.expectEqual(@as(i32, 9), first.delay_milliseconds);

    const second = periodicTimerSchedule(9 * std.time.ns_per_ms, first.deadline_nanoseconds, interval);
    try std.testing.expectEqual(@as(i96, 16_666_666), second.deadline_nanoseconds);
    try std.testing.expectEqual(@as(i32, 8), second.delay_milliseconds);

    const third = periodicTimerSchedule(17 * std.time.ns_per_ms, second.deadline_nanoseconds, interval);
    try std.testing.expectEqual(@as(i96, 24_999_999), third.deadline_nanoseconds);
    try std.testing.expectEqual(@as(i32, 8), third.delay_milliseconds);
}

test "repaint delay leaves the render budget and margin before vblank" {
    // 16.7ms until vblank with a 4ms budget: start 2ms margin plus budget
    // early, rounded down to whole milliseconds.
    try std.testing.expectEqual(@as(?i32, 10), repaintDelayFromDeadline(
        0,
        16_700_000,
        4 * std.time.ns_per_ms,
    ));
    // The budget consumes the whole period: render immediately.
    try std.testing.expectEqual(@as(?i32, null), repaintDelayFromDeadline(
        0,
        16_700_000,
        15 * std.time.ns_per_ms,
    ));
    // A sub-threshold delay is not worth the timer round-trip.
    try std.testing.expectEqual(@as(?i32, null), repaintDelayFromDeadline(
        0,
        16_700_000,
        13 * std.time.ns_per_ms,
    ));
    // A deadline already in the past renders immediately.
    try std.testing.expectEqual(@as(?i32, null), repaintDelayFromDeadline(
        20_000_000,
        16_700_000,
        std.time.ns_per_ms,
    ));
}

test "render budget samples the later of GPU completion and commit" {
    const presented: i96 = 16_666_666;
    // GPU completion after commit: the fence signal bounds the sample.
    try std.testing.expectEqual(
        RenderBudgetUpdate{ .sample = 5 * std.time.ns_per_ms },
        renderBudgetUpdate(.composited, 0, 5 * std.time.ns_per_ms, presented, null),
    );
    // Overlay scanout still renders the primary plane and samples too.
    try std.testing.expectEqual(
        RenderBudgetUpdate{ .sample = 4 * std.time.ns_per_ms },
        renderBudgetUpdate(.overlay_scanout, 0, 4 * std.time.ns_per_ms, presented, null),
    );
    // Direct scanout renders nothing and contributes no sample.
    try std.testing.expectEqual(
        RenderBudgetUpdate.ignore,
        renderBudgetUpdate(.direct_scanout, 0, null, presented, null),
    );
    // Unknown GPU completion disables delays rather than guessing.
    try std.testing.expectEqual(
        RenderBudgetUpdate{ .reset = .no_timing },
        renderBudgetUpdate(.composited, 0, null, presented, null),
    );
    // A ready timestamp outside render-to-presentation is untrustworthy.
    try std.testing.expectEqual(
        RenderBudgetUpdate{ .reset = .no_timing },
        renderBudgetUpdate(.composited, 0, presented + 1, presented, null),
    );
}

test "render budget resets when a delayed frame misses its target vblank" {
    const target: i96 = 16_666_666;
    const late = target + 2 * std.time.ns_per_ms;
    try std.testing.expectEqual(
        RenderBudgetUpdate{ .reset = .missed_deadline },
        renderBudgetUpdate(.composited, 0, 5 * std.time.ns_per_ms, late, target),
    );
    // Overlay and direct scanout misses must also invalidate a stale
    // budget so delayed frames cannot keep missing the same vblank.
    try std.testing.expectEqual(
        RenderBudgetUpdate{ .reset = .missed_deadline },
        renderBudgetUpdate(.overlay_scanout, 0, 5 * std.time.ns_per_ms, late, target),
    );
    try std.testing.expectEqual(
        RenderBudgetUpdate{ .reset = .missed_deadline },
        renderBudgetUpdate(.direct_scanout, 0, null, late, target),
    );
    // Presentation within the jitter tolerance of the target still samples.
    try std.testing.expectEqual(
        RenderBudgetUpdate{ .sample = 5 * std.time.ns_per_ms },
        renderBudgetUpdate(
            .composited,
            0,
            5 * std.time.ns_per_ms,
            target + repaint_miss_tolerance_nanoseconds,
            target,
        ),
    );
    // An immediate frame targets no vblank; even a slow presentation only
    // feeds the sample window instead of resetting the budget.
    try std.testing.expectEqual(
        RenderBudgetUpdate{ .sample = 5 * std.time.ns_per_ms },
        renderBudgetUpdate(.composited, 0, 5 * std.time.ns_per_ms, late, null),
    );
}

test "render budget requires a full window and tracks the worst frame" {
    var budget: RenderBudget = .{};
    try std.testing.expectEqual(@as(?u64, null), budget.budgetNanoseconds());
    for (0..RenderBudget.sample_capacity - 1) |_| budget.record(std.time.ns_per_ms);
    try std.testing.expectEqual(@as(?u64, null), budget.budgetNanoseconds());
    budget.record(3 * std.time.ns_per_ms);
    try std.testing.expectEqual(
        @as(?u64, 3 * std.time.ns_per_ms),
        budget.budgetNanoseconds(),
    );
    // The worst sample eventually rolls out of the window.
    for (0..RenderBudget.sample_capacity) |_| budget.record(2 * std.time.ns_per_ms);
    try std.testing.expectEqual(
        @as(?u64, 2 * std.time.ns_per_ms),
        budget.budgetNanoseconds(),
    );
    // A reset disables delays until the window refills.
    budget.reset();
    try std.testing.expectEqual(@as(?u64, null), budget.budgetNanoseconds());
}

const RoutedKey = struct {
    device_id: NativeInput.DeviceId,
    seat: *Seat,
    key: u32,
};

const RoutedButton = struct {
    source: PointerButtonSource,
    seat: *Seat,
    button: u32,
};

const PointerButtonSource = union(enum) {
    native: NativeInput.DeviceId,
    virtual: u64,
};

const GestureKind = enum { swipe, pinch, hold };

const RoutedGesture = struct {
    device_id: NativeInput.DeviceId,
    seat: *Seat,
    kind: GestureKind,
};

const RoutedTouch = struct {
    device_id: NativeInput.DeviceId,
    native_id: i32,
    seat: *Seat,
    protocol_id: i32,
};

const PointerRoute = struct {
    focus: ?Seat.PointerFocus,
    root: ?Surface.Id,
};

const RenderOutputStore = slot_map.SlotMap(*RenderOutput, enum { render_output });
const RenderOutputId = RenderOutputStore.Id;

const XwaylandWindow = struct {
    scene_id: Scene.Id,
    surface_id: Surface.Id,
};

const RenderOutputConfig = struct {
    kind: OutputBackend.Kind,
    size: render.Size,
    scale: render.Scale = .{},
    refresh_millihertz: i32 = 60_000,
    position: Output.Position = .{},
    name: []const u8,
    description: []const u8,
    make: []const u8 = "keywork",
    model: []const u8,
    drm_output: ?*DrmOutput = null,
};

const PreparedIccProfile = struct {
    output: *DrmOutput,
    profile: ?Icc.OutputProfile,
    owned_path: ?[]u8,
    color_description: render.ColorDescription,
    color_identity: u64 = 0,
};

pub const VirtualOutputConfig = struct {
    size: render.Size = .{ .width = 1280, .height = 720 },
    scale: render.Scale = .{},
    refresh_millihertz: i32 = 60_000,
};

const OutputFrame = struct {
    render_output: *RenderOutput,
    output: *Output,
    visible_rect: render.Rect,
    track_visibility: bool,
    presentation_damage: ?*const Region = null,
    next_backdrop_capture_id: *u32,
};

const WindowTransition = struct {
    kind: enum { reflow, appearance, disappearance },
    scene_id: Scene.Id,
    root_id: Surface.Id,
    output_id: OutputLayout.Id,
    old_rect: WindowAnimation.Rect,
    target_rect: WindowAnimation.Rect,
    old_source_cache: render.SourceCache,
    buffer_update_required: bool,
    old: WindowAnimation.Snapshot,
    target: ?WindowAnimation.Snapshot = null,
    target_dirty: bool = false,
    coordinated: bool = false,
    // Split-coordinated transitions slide at full opacity; centered 0 <-> 1 transitions fade.
    opacity_transition: bool = true,
    detached: bool = false,
    effects: ?Scene.Effects = null,
    borders: ?Scene.Borders = null,
    phase: enum { waiting, target_pending, animating } = .waiting,
    start: i96 = 0,
    duration: u64,
    easing: WindowAnimation.Easing,
};

const maximum_window_transitions = 64;

const WorkspaceTransition = struct {
    output_id: OutputLayout.Id,
    rect: WindowAnimation.Rect,
    old: WindowAnimation.Snapshot,
    transparent: WindowAnimation.Snapshot,
    phase: enum { pending, animating } = .pending,
    start: i96 = 0,
};

fn allocateBackdropCaptureId(frame: *const OutputFrame) Renderer.Error!u32 {
    const id = frame.next_backdrop_capture_id.*;
    if (id == std.math.maxInt(u32)) return error.InvalidTarget;
    frame.next_backdrop_capture_id.* = id + 1;
    return id;
}

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    renderer_kind: Renderer.Kind,
    output_kind: OutputBackend.Kind,
    drm_device_path: ?[]const u8,
) !*Self {
    return createWithVirtualOutput(
        allocator,
        io,
        renderer_kind,
        output_kind,
        drm_device_path,
        .{},
    );
}

pub fn createWithVirtualOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    renderer_kind: Renderer.Kind,
    output_kind: OutputBackend.Kind,
    drm_device_path: ?[]const u8,
    virtual_output: VirtualOutputConfig,
) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const display = try wl.Server.create();
    errdefer display.destroy();
    display.addProtocolLogger(*wl.Server, logProtocolError, display);
    try display.initShm();

    self.* = .{
        .allocator = allocator,
        .io = io,
        .display = display,
        .control = undefined,
        .control_initialized = false,
        .appearance_client = undefined,
        .appearance_client_initialized = false,
        .configuration = null,
        .palette = theme.default_palette,
        .reduced_motion = false,
        .session = undefined,
        .session_initialized = false,
        .drm_device = undefined,
        .drm_device_initialized = false,
        .native_input = undefined,
        .native_input_initialized = false,
        .input_manager = undefined,
        .input_manager_initialized = false,
        .builtin_keybindings = undefined,
        .builtin_keybindings_initialized = false,
        .render_outputs = .{},
        .primary_render_output = undefined,
        .outputs = undefined,
        .xdg_output = undefined,
        .xdg_output_initialized = false,
        .output_management = undefined,
        .output_management_initialized = false,
        .output_power = undefined,
        .output_power_initialized = false,
        .gamma_control = undefined,
        .gamma_control_initialized = false,
        .drm_lease = undefined,
        .drm_lease_initialized = false,
        .single_pixel_buffer = undefined,
        .content_type = undefined,
        .color_management = undefined,
        .color_representation = undefined,
        .alpha_modifier = undefined,
        .background_effect = undefined,
        .security_context = undefined,
        .session_lock = undefined,
        .session_lock_initialized = false,
        .cursor_shape = undefined,
        .tablet = undefined,
        .relative_pointer = undefined,
        .pointer_gestures = undefined,
        .pointer_constraints = undefined,
        .pointer_warp = undefined,
        .idle_inhibit = undefined,
        .keyboard_shortcuts_inhibit = undefined,
        .idle_notify = undefined,
        .idle_notify_initialized = false,
        .compositor = undefined,
        .subcompositor = undefined,
        .scene = undefined,
        .xdg_shell = undefined,
        .gtk_shell = undefined,
        .xdg_foreign = undefined,
        .layer_shell = undefined,
        .layer_shell_initialized = false,
        .seat = undefined,
        .transient_seat = undefined,
        .input_device_listener = .{
            .context = self,
            .added = inputDeviceAdded,
            .removed = inputDeviceRemoved,
        },
        .routed_keys = .empty,
        .routed_buttons = .empty,
        .routed_gestures = .empty,
        .routed_touches = .empty,
        .next_touch_id = 0,
        .data_device = undefined,
        .xdg_toplevel_drag = undefined,
        .xdg_toplevel_icon = undefined,
        .xdg_dialog = undefined,
        .xdg_system_bell = undefined,
        .xdg_toplevel_tag = undefined,
        .xdg_session_management = undefined,
        .primary_selection = undefined,
        .data_control = undefined,
        .foreign_toplevel_list = undefined,
        .foreign_toplevel_list_initialized = false,
        .image_capture_source = undefined,
        .image_capture_source_initialized = false,
        .image_copy_capture = undefined,
        .image_copy_capture_initialized = false,
        .screencopy = undefined,
        .screencopy_initialized = false,
        .composed_capture_source = null,
        .xwayland_keyboard_grab = undefined,
        .xwayland_keyboard_grab_initialized = false,
        .xwayland_shell = undefined,
        .xwayland_shell_initialized = false,
        .xwayland_server = undefined,
        .xwayland_server_initialized = false,
        .xwm = undefined,
        .xwm_initialized = false,
        .xwayland_windows = .empty,
        .xwayland_client_stack = .empty,
        .xwayland_override_redirect_focus = null,
        .workspace = undefined,
        .workspace_initialized = false,
        .text_input = undefined,
        .input_method = undefined,
        .virtual_keyboard = undefined,
        .virtual_pointer = undefined,
        .presentation_protocol = undefined,
        .fractional_scale = undefined,
        .fixes = undefined,
        .linux_dmabuf = undefined,
        .linux_drm_syncobj = undefined,
        .tearing_control = undefined,
        .fifo = undefined,
        .commit_timing = undefined,
        .xdg_activation = undefined,
        .viewporter = undefined,
        .window_manager = undefined,
        .window_manager_initialized = false,
        .window_transitions = .empty,
        .workspace_transitions = .empty,
        .animation_now = 0,
        .renderer = undefined,
        .socket_buffer = undefined,
        .listening = false,
        .xwayland_display_listener = null,
    };
    errdefer self.routed_touches.deinit(allocator);
    errdefer self.routed_gestures.deinit(allocator);
    errdefer self.routed_buttons.deinit(allocator);
    errdefer self.routed_keys.deinit(allocator);
    errdefer self.render_outputs.deinit(allocator);
    errdefer self.xwayland_windows.deinit(allocator);
    errdefer self.xwayland_client_stack.deinit(allocator);
    errdefer self.window_transitions.deinit(allocator);
    errdefer self.workspace_transitions.deinit(allocator);
    if (output_kind == .drm) {
        try self.session.init(allocator, display.getEventLoop());
        self.session_initialized = true;
        errdefer self.session.deinit();
        try self.drm_device.init(
            allocator,
            io,
            display.getEventLoop(),
            &self.session,
            drm_device_path,
        );
        self.drm_device_initialized = true;
    }
    self.renderer = Renderer.initForDevice(
        allocator,
        renderer_kind,
        if (output_kind == .drm) self.drm_device.deviceId() else null,
    ) catch |err| {
        if (output_kind == .drm) {
            self.drm_device.deinit();
            self.session.deinit();
        }
        return err;
    };
    errdefer if (output_kind == .drm) self.session.deinit();
    errdefer self.renderer.deinit();
    errdefer if (output_kind == .drm) self.drm_device.deinit();
    try self.compositor.init(allocator, display);
    errdefer self.compositor.deinit();
    try self.security_context.init(allocator, display);
    errdefer self.security_context.deinit();
    self.outputs.init(allocator, display, self.compositor.surfaceStore());
    errdefer self.outputs.deinit();
    try self.color_management.init(
        allocator,
        display,
        &self.outputs,
        self.renderer.supportsColorManagement(),
    );
    errdefer self.color_management.deinit();
    try self.color_representation.init(allocator, display);
    errdefer self.color_representation.deinit();
    try self.alpha_modifier.init(allocator, display);
    errdefer self.alpha_modifier.deinit();
    try self.seat.init(allocator, io, display, "default", self.compositor.surfaceStore());
    errdefer self.seat.deinit();
    // Headless outputs have no parent window that can deliver keyboard enter.
    if (output_kind == .headless) self.seat.ensureParentKeyboardEnter();
    try self.transient_seat.init(
        allocator,
        io,
        display,
        self.compositor.surfaceStore(),
        &self.security_context,
    );
    errdefer self.transient_seat.deinit();
    var render_output_id: RenderOutputId = undefined;
    errdefer {
        var it = self.render_outputs.iterator();
        while (it.next()) |entry| std.debug.assert(self.removeRenderOutput(entry.id));
    }
    if (output_kind == .drm) {
        const drm_outputs = self.drm_device.outputs();
        if (drm_outputs.len == 0) return error.NoConnectedOutput;
        var x: i32 = 0;
        for (drm_outputs, 0..) |drm_output, index| {
            std.debug.assert(drm_output.enabled);
            drm_output.logical_x = x;
            drm_output.logical_y = 0;
            const id = try self.addRenderOutput(io, .{ .kind = .drm, .size = drm_output.size, .position = .{ .x = x }, .name = "DRM", .description = "Keywork DRM output", .model = "drm-kms", .drm_output = drm_output });
            if (index == 0) render_output_id = id;
            x = std.math.add(i32, x, @intCast(drm_output.logicalSize().width)) catch
                return error.InvalidOutputGeometry;
        }
    } else render_output_id = try self.addRenderOutput(io, .{
        .kind = output_kind,
        .size = virtual_output.size,
        .scale = virtual_output.scale,
        .refresh_millihertz = virtual_output.refresh_millihertz,
        .name = if (output_kind == .headless) "HEADLESS-1" else "NESTED-1",
        .description = if (output_kind == .headless) "Keywork headless output" else "Keywork nested output",
        .model = if (output_kind == .headless) "headless" else "nested-wayland",
    });
    self.primary_render_output = render_output_id;
    const render_output = self.render_outputs.get(render_output_id).?.*;
    try self.xdg_output.init(allocator, display, &self.outputs);
    self.xdg_output_initialized = true;
    errdefer {
        self.xdg_output.deinit();
        self.xdg_output_initialized = false;
    }
    if (output_kind != .nested) {
        try self.output_management.init(
            allocator,
            display,
            if (output_kind == .drm) self.drm_device.outputs() else &.{},
            &self.security_context,
            .{
                .context = self,
                .test_configuration = testOutputConfiguration,
                .apply = applyOutputConfiguration,
            },
        );
        self.output_management_initialized = true;
        errdefer {
            self.output_management.deinit();
            self.output_management_initialized = false;
        }
        if (output_kind == .headless) {
            const protocol_output = self.outputs.get(render_output.protocol_id).?;
            try self.output_management.addVirtualHead(.{
                .output = protocol_output,
                .mode_size = render_output.backend.modeSize(),
                .refresh_millihertz = render_output.backend.refreshMillihertz(),
                .physical_size = render_output.backend.physicalSize(),
                .make = "keywork",
                .model = "headless",
            });
        }
    }
    if (output_kind == .drm) {
        try self.output_power.init(
            allocator,
            display,
            &self.outputs,
            &self.security_context,
            .{
                .context = self,
                .powered = outputPowerState,
                .set_powered = setOutputPowerState,
            },
        );
        self.output_power_initialized = true;
        errdefer {
            self.output_power.deinit();
            self.output_power_initialized = false;
        }
        try self.gamma_control.init(
            allocator,
            io,
            display,
            &self.outputs,
            &self.security_context,
            .{
                .context = self,
                .gamma_size = outputGammaSize,
                .set_gamma = setOutputGamma,
                .reset_gamma = resetOutputGamma,
            },
        );
        self.gamma_control_initialized = true;
        errdefer {
            self.gamma_control.deinit();
            self.gamma_control_initialized = false;
        }
        try self.drm_lease.init(
            allocator,
            display,
            &self.security_context,
            self.drm_device.outputs(),
            .{
                .context = self,
                .open_fd = openDrmLeaseDevice,
                .grant = grantDrmLease,
                .revoke = revokeDrmLease,
            },
        );
        self.drm_lease_initialized = true;
        errdefer {
            self.drm_lease.deinit();
            self.drm_lease_initialized = false;
        }
    }
    try self.single_pixel_buffer.init(allocator, display);
    errdefer self.single_pixel_buffer.deinit();
    try self.content_type.init(allocator, display);
    errdefer self.content_type.deinit();
    try self.background_effect.init(allocator, display);
    errdefer self.background_effect.deinit();
    try self.session_lock.init(
        allocator,
        display,
        &self.outputs,
        self.compositor.surfaceStore(),
        &self.security_context,
        .{
            .context = self,
            .state_changed = sessionLockStateChanged,
            .output_secure_without_frame = outputSecureWithoutFrame,
            .repaint = requestRepaint,
        },
    );
    self.session_lock_initialized = true;
    errdefer {
        self.session_lock.deinit();
        self.session_lock_initialized = false;
    }
    try self.tablet.init(
        allocator,
        display,
        self.compositor.surfaceStore(),
        .{
            .context = self,
            .surface_coordinates = tabletSurfaceCoordinates,
            .repaint = requestRepaint,
        },
    );
    errdefer self.tablet.deinit();
    try self.cursor_shape.init(allocator, display, &self.tablet, .{
        .context = self,
        .clear_shapes = clearCursorShapes,
    });
    errdefer self.cursor_shape.deinit();
    self.seat.setDefaultCursor(self.cursor_shape.defaultCursor());
    try self.relative_pointer.init(allocator, display, &self.seat);
    errdefer self.relative_pointer.deinit();
    try self.pointer_gestures.init(allocator, display);
    errdefer self.pointer_gestures.deinit();
    try self.pointer_constraints.init(
        allocator,
        display,
        &self.seat,
        self.compositor.surfaceStore(),
    );
    errdefer self.pointer_constraints.deinit();
    try self.pointer_warp.init(
        display,
        &self.seat,
        self.compositor.surfaceStore(),
        .{ .context = self, .warp = pointerWarp },
    );
    errdefer self.pointer_warp.deinit();
    try self.idle_inhibit.init(allocator, display, .{
        .context = self,
        .changed = idleInhibitorsChanged,
    });
    errdefer self.idle_inhibit.deinit();
    try self.keyboard_shortcuts_inhibit.init(allocator, display);
    errdefer self.keyboard_shortcuts_inhibit.deinit();
    try self.presentation_protocol.init(
        allocator,
        display,
        self.compositor.surfaceStore(),
        render_output.backend.presentationClockId(),
    );
    errdefer self.presentation_protocol.deinit();
    try self.viewporter.init(allocator, display);
    errdefer self.viewporter.deinit();
    try self.fractional_scale.init(
        allocator,
        display,
        &self.outputs,
        render_output.protocol_id,
    );
    errdefer self.fractional_scale.deinit();
    try self.fixes.init(display);
    errdefer self.fixes.deinit();
    try self.linux_dmabuf.init(
        allocator,
        io,
        display,
        self.renderer.dmabufDeviceId(),
        if (output_kind == .drm) self.drm_device.deviceId() else null,
        self.renderer.dmabufSourceFormats(),
        render_output.backend.scanoutFormats(),
        self.renderer.dmabufSourceValidator(),
    );
    errdefer self.linux_dmabuf.deinit();
    try self.linux_drm_syncobj.init(
        allocator,
        io,
        display,
        self.renderer.dmabufDeviceId(),
    );
    errdefer self.linux_drm_syncobj.deinit();
    try self.tearing_control.init(allocator, display);
    errdefer self.tearing_control.deinit();
    try self.fifo.init(allocator, display);
    errdefer self.fifo.deinit();
    try self.commit_timing.init(
        allocator,
        display,
        self.compositor.surfaceStore(),
        render_output.backend.presentationClockId(),
        .{ .context = self, .failed = commitTimingFailed },
    );
    errdefer self.commit_timing.deinit();
    try self.subcompositor.init(allocator, display, self.compositor.surfaceStore());
    errdefer self.subcompositor.deinit();
    self.scene.init(allocator);
    errdefer self.scene.deinit();
    try self.idle_notify.init(allocator, io, display, .{
        .context = self,
        .failed = idleNotifyFailed,
    });
    self.idle_notify_initialized = true;
    errdefer {
        self.idle_notify.deinit();
        self.idle_notify_initialized = false;
    }
    try self.gtk_shell.init(allocator, display, &self.seat);
    errdefer self.gtk_shell.deinit();
    try self.xdg_shell.init(
        allocator,
        display,
        self.compositor.surfaceStore(),
        &self.subcompositor,
        &self.scene,
        &self.seat,
        &self.outputs,
        render_output.protocol_id,
        &self.gtk_shell,
    );
    errdefer self.xdg_shell.deinit();
    try self.xdg_foreign.init(allocator, io, display, &self.xdg_shell);
    errdefer self.xdg_foreign.deinit();
    try self.layer_shell.init(
        allocator,
        display,
        &self.outputs,
        render_output.protocol_id,
        &self.scene,
        &self.seat,
        &self.xdg_shell,
        self.compositor.surfaceStore(),
    );
    self.layer_shell_initialized = true;
    errdefer {
        self.layer_shell.deinit();
        self.layer_shell_initialized = false;
    }
    try self.xdg_activation.init(allocator, io, display, &self.seat);
    errdefer self.xdg_activation.deinit();
    try self.data_device.init(
        allocator,
        display,
        &self.seat,
        self.compositor.surfaceStore(),
        .{
            .context = self,
            .started = dragStarted,
            .ended = dragEnded,
            .external_source_destroyed = dragExternalSourceDestroyed,
            .repaint = requestRepaint,
        },
    );
    errdefer self.data_device.deinit();
    try self.primary_selection.init(allocator, display, &self.seat);
    errdefer self.primary_selection.deinit();
    try self.data_control.init(
        allocator,
        display,
        &self.security_context,
        &self.seat,
        &self.data_device,
        &self.primary_selection,
    );
    errdefer self.data_control.deinit();
    try self.text_input.init(
        allocator,
        display,
        &self.seat,
        self.compositor.surfaceStore(),
    );
    errdefer self.text_input.deinit();
    try self.input_method.init(
        allocator,
        display,
        &self.security_context,
        &self.seat,
        self.compositor.surfaceStore(),
        &self.text_input,
        .{
            .context = self,
            .surface_position = inputMethodSurfacePosition,
            .output_size = inputMethodOutputSize,
            .repaint = requestRepaint,
        },
    );
    errdefer self.input_method.deinit();
    try self.virtual_keyboard.init(
        allocator,
        io,
        display,
        &self.security_context,
        &self.seat,
        &self.transient_seat,
    );
    errdefer self.virtual_keyboard.deinit();
    try self.virtual_pointer.init(
        allocator,
        display,
        &self.security_context,
        &self.seat,
        &self.transient_seat,
        &self.outputs,
        .{ .context = self, .event = virtualPointerEvent },
    );
    errdefer self.virtual_pointer.deinit();
    try self.workspace.init(allocator, display, &self.security_context, &self.outputs);
    self.workspace_initialized = true;
    errdefer {
        self.workspace.deinit();
        self.workspace_initialized = false;
    }
    try self.window_manager.init(
        allocator,
        display,
        &self.outputs,
        &self.seat,
        render_output.protocol_id,
        &self.scene,
        &self.xdg_shell,
        .{
            .context = self,
            .window_info = xwaylandWindowInfo,
            .resize = resizeXwaylandWindow,
            .move = moveXwaylandWindow,
            .set_fullscreen = setXwaylandWindowFullscreen,
            .set_maximized = setXwaylandWindowMaximized,
            .set_minimized = setXwaylandWindowMinimized,
            .close = closeXwaylandWindow,
            .refresh_scene = refreshXwaylandScene,
            .stacking_changed = xwaylandStackingChanged,
        },
        &self.layer_shell,
        &self.workspace,
    );
    self.window_manager_initialized = true;
    self.window_manager.setGeometryTransitionListener(.{
        .context = self,
        .prepare = geometryTransitionPrepare,
        .published = geometryTransitionPublished,
        .appeared = geometryTransitionAppeared,
        .closing = geometryTransitionClosing,
        .removed = geometryTransitionRemoved,
        .workspace_switching = workspaceTransitionPrepare,
        .workspace_published = workspaceTransitionPublished,
    });
    errdefer {
        self.window_manager.clearGeometryTransitionListener();
        self.window_manager.deinit();
        self.window_manager_initialized = false;
    }
    self.xdg_activation.setActivationListener(.{
        .context = self,
        .requested = xdgActivationRequested,
    });
    errdefer self.xdg_activation.clearActivationListener();
    try self.xdg_toplevel_drag.init(
        allocator,
        display,
        &self.data_device,
        &self.xdg_shell,
        &self.seat,
        .{
            .context = self,
            .begin = xdgToplevelDragBegin,
            .motion = xdgToplevelDragMotion,
            .end = xdgToplevelDragEnd,
        },
    );
    errdefer self.xdg_toplevel_drag.deinit();
    try self.xdg_toplevel_icon.init(allocator, display, &self.xdg_shell);
    errdefer self.xdg_toplevel_icon.deinit();
    try self.xdg_dialog.init(allocator, display, &self.xdg_shell);
    errdefer self.xdg_dialog.deinit();
    try self.xdg_system_bell.init(display);
    errdefer self.xdg_system_bell.deinit();
    try self.xdg_toplevel_tag.init(display, &self.xdg_shell);
    errdefer self.xdg_toplevel_tag.deinit();
    try self.xdg_session_management.init(
        allocator,
        io,
        display,
        &self.xdg_shell,
        &self.window_manager,
    );
    errdefer self.xdg_session_management.deinit();
    self.workspace.setActivationListener(.{
        .context = self,
        .activate = workspaceActivationRequested,
    });
    errdefer self.workspace.clearActivationListener();
    try self.foreign_toplevel_list.init(
        allocator,
        display,
        &self.security_context,
        &self.xdg_shell,
        .{
            .context = self,
            .window_info = xwaylandWindowInfo,
            .close = closeXwaylandWindow,
            .request_activation = requestXwaylandWindowActivation,
            .request_fullscreen = requestXwaylandWindowFullscreen,
            .request_maximized = requestXwaylandWindowMaximized,
            .request_minimized = requestXwaylandWindowMinimized,
        },
        &self.outputs,
    );
    self.foreign_toplevel_list_initialized = true;
    errdefer {
        self.foreign_toplevel_list.deinit();
        self.foreign_toplevel_list_initialized = false;
    }
    try self.image_capture_source.init(
        allocator,
        display,
        &self.security_context,
        &self.outputs,
        &self.foreign_toplevel_list,
        &self.xdg_shell,
    );
    self.image_capture_source_initialized = true;
    errdefer {
        self.image_capture_source.deinit();
        self.image_capture_source_initialized = false;
    }
    try self.image_copy_capture.init(
        allocator,
        display,
        &self.security_context,
        &self.image_capture_source,
        &self.linux_dmabuf,
        .{
            .context = self,
            .constraints = captureConstraints,
            .schedule = scheduleImageCapture,
            .capture = captureImage,
            .capture_dmabuf = captureImageDmabuf,
            .complete = completeCaptureReadback,
            .cursor_info = captureCursorInfo,
        },
    );
    self.image_copy_capture_initialized = true;
    errdefer {
        self.image_copy_capture.deinit();
        self.image_copy_capture_initialized = false;
    }
    try self.screencopy.init(
        allocator,
        display,
        &self.security_context,
        &self.outputs,
        &self.linux_dmabuf,
        .{
            .context = self,
            .constraints = screencopyConstraints,
            .schedule = scheduleScreencopy,
            .capture = captureScreencopy,
            .capture_dmabuf = captureScreencopyDmabuf,
            .complete = completeCaptureReadback,
        },
    );
    self.screencopy_initialized = true;
    errdefer {
        self.screencopy.deinit();
        self.screencopy_initialized = false;
    }
    try self.xwayland_shell.init(
        allocator,
        display,
        &self.security_context,
        .{
            .context = self,
            .associated = xwaylandSurfaceAssociated,
            .committed = xwaylandSurfaceCommitted,
            .removed = xwaylandSurfaceRemoved,
        },
    );
    self.xwayland_shell_initialized = true;
    errdefer {
        self.xwayland_shell.deinit();
        self.xwayland_shell_initialized = false;
    }
    try self.xwayland_keyboard_grab.init(allocator, display, &self.security_context);
    self.xwayland_keyboard_grab_initialized = true;
    errdefer {
        self.xwayland_keyboard_grab.deinit();
        self.xwayland_keyboard_grab_initialized = false;
    }
    self.xwayland_server.init(
        allocator,
        display,
        &self.xwayland_shell,
        &self.xwayland_keyboard_grab,
        .{
            .context = self,
            .ready = xwaylandReady,
            .stopped = xwaylandStopped,
            .unavailable = xwaylandUnavailable,
        },
    );
    self.xwayland_server_initialized = true;
    errdefer {
        self.xwayland_server.deinit();
        self.xwayland_server_initialized = false;
    }
    self.subcompositor.setRepaintListener(.{
        .context = self,
        .request = requestRepaint,
        .surface_changed = surfaceChanged,
    });
    self.scene.setRepaintListener(.{
        .context = self,
        .request = requestRepaint,
        .surface_changed = surfaceChanged,
        .window_changed = sceneWindowChanged,
        .node_damage = sceneNodeDamage,
        .visibility_changed = sceneVisibilityChanged,
    });
    self.seat.setRepaintListener(.{
        .context = self,
        .request = requestRepaint,
        .cursor_changed = cursorChanged,
    });
    self.layer_shell.setRepaintListener(.{
        .context = self,
        .request = requestRepaint,
    });
    if (output_kind == .drm) {
        try self.native_input.init(
            allocator,
            io,
            display.getEventLoop(),
            &self.session,
            render_output.backend.size(),
            nativeInputListener(render_output),
        );
        self.native_input_initialized = true;
        errdefer {
            self.native_input.deinit();
            self.native_input_initialized = false;
        }
    }
    const native_input = if (self.native_input_initialized) &self.native_input else null;
    try self.input_manager.init(allocator, native_input);
    self.input_manager_initialized = true;
    errdefer {
        self.input_manager.detachNativeInput();
        self.input_manager.deinit();
        self.input_manager_initialized = false;
    }
    try self.input_manager.addDeviceListener(&self.input_device_listener);
    errdefer self.input_manager.removeDeviceListener(&self.input_device_listener);
    try self.builtin_keybindings.init(
        allocator,
        self.display,
        &self.window_manager,
        &self.input_manager,
        &self.keyboard_shortcuts_inhibit,
        native_input,
    );
    self.builtin_keybindings_initialized = true;
    errdefer {
        self.builtin_keybindings.deinit();
        self.builtin_keybindings_initialized = false;
    }
    try render_output.backend.startInput();
    requestRepaint(self);

    if (output_kind == .drm) self.drm_device.setListener(.{
        .context = self,
        .added = drmOutputAdded,
        .removing = drmOutputRemoving,
        .failed = drmDeviceFailed,
        .activated = drmDeviceActivated,
        .deactivating = drmDeviceDeactivating,
        .changed = drmOutputChanged,
        .lease_revoked = drmLeaseRevoked,
    });

    return self;
}

pub fn configureXdgSessionStorage(
    self: *Self,
    runtime_directory: []const u8,
    instance_name: []const u8,
) !void {
    try self.xdg_session_management.configureStorage(runtime_directory, instance_name);
}

pub fn destroy(self: *Self) void {
    const allocator = self.allocator;
    if (self.appearance_client_initialized) {
        self.appearance_client.deinit();
        self.appearance_client_initialized = false;
    }
    if (self.control_initialized) {
        self.control.deinit();
        self.control_initialized = false;
    }
    if (self.drm_lease_initialized) self.drm_lease.@"suspend"();
    if (self.drm_device_initialized) self.drm_device.clearListener();
    self.data_device.cancel();
    if (self.builtin_keybindings_initialized) self.builtin_keybindings.detachNativeInput();
    if (self.input_manager_initialized) {
        self.input_manager.detachNativeInput();
        self.input_manager.removeDeviceListener(&self.input_device_listener);
    }
    if (self.native_input_initialized) self.native_input.deinit();
    self.layer_shell.clearRepaintListener();
    self.seat.clearRepaintListener();
    self.scene.clearRepaintListener();
    self.subcompositor.clearRepaintListener();
    self.window_manager.clearGeometryTransitionListener();
    finishAllWindowTransitions(self);
    finishAllWorkspaceTransitions(self);
    var render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| stopRenderOutput(entry.value.*);
    self.display.destroyClients();
    if (self.drm_device_initialized) self.drm_device.releaseClientBuffers();
    if (self.builtin_keybindings_initialized) {
        self.builtin_keybindings.deinit();
        self.builtin_keybindings_initialized = false;
    }
    if (self.configuration) |*configuration| {
        configuration.deinit();
        self.configuration = null;
    }
    if (self.input_manager_initialized) {
        self.input_manager.deinit();
        self.input_manager_initialized = false;
    }
    if (self.drm_lease_initialized) {
        self.drm_lease.deinit();
        self.drm_lease_initialized = false;
    }
    if (self.gamma_control_initialized) {
        self.gamma_control.deinit();
        self.gamma_control_initialized = false;
    }
    if (self.output_power_initialized) {
        self.output_power.deinit();
        self.output_power_initialized = false;
    }
    if (self.output_management_initialized) {
        self.output_management.deinit();
        self.output_management_initialized = false;
    }
    self.xwayland_server.deinit();
    self.xwayland_server_initialized = false;
    std.debug.assert(self.xwayland_windows.count() == 0);
    self.xwayland_windows.deinit(allocator);
    self.xwayland_client_stack.deinit(allocator);
    self.xwayland_keyboard_grab.deinit();
    self.xwayland_keyboard_grab_initialized = false;
    self.xwayland_shell.deinit();
    self.xwayland_shell_initialized = false;
    self.screencopy.deinit();
    self.screencopy_initialized = false;
    self.image_copy_capture.deinit();
    self.image_copy_capture_initialized = false;
    self.image_capture_source.deinit();
    self.image_capture_source_initialized = false;
    self.foreign_toplevel_list.deinit();
    self.foreign_toplevel_list_initialized = false;
    self.workspace.clearActivationListener();
    self.xdg_session_management.deinit();
    self.xdg_toplevel_tag.deinit();
    self.xdg_system_bell.deinit();
    self.xdg_dialog.deinit();
    self.xdg_toplevel_icon.deinit();
    self.xdg_toplevel_drag.deinit();
    self.xdg_activation.clearActivationListener();
    self.window_manager.deinit();
    self.window_manager_initialized = false;
    self.workspace.deinit();
    self.workspace_initialized = false;
    self.virtual_pointer.deinit();
    self.virtual_keyboard.deinit();
    self.transient_seat.deinit();
    self.input_method.deinit();
    self.text_input.deinit();
    self.data_control.deinit();
    self.primary_selection.deinit();
    self.data_device.deinit();
    self.xdg_activation.deinit();
    self.idle_notify.deinit();
    self.idle_notify_initialized = false;
    self.layer_shell.deinit();
    self.layer_shell_initialized = false;
    self.xdg_foreign.deinit();
    self.xdg_shell.deinit();
    self.gtk_shell.deinit();
    self.scene.deinit();
    self.subcompositor.deinit();
    self.commit_timing.deinit();
    self.fifo.deinit();
    self.tearing_control.deinit();
    self.linux_drm_syncobj.deinit();
    self.linux_dmabuf.deinit();
    self.fixes.deinit();
    self.fractional_scale.deinit();
    self.viewporter.deinit();
    self.presentation_protocol.deinit();
    self.keyboard_shortcuts_inhibit.deinit();
    self.idle_inhibit.deinit();
    self.pointer_warp.deinit();
    self.pointer_constraints.deinit();
    self.pointer_gestures.deinit();
    self.relative_pointer.deinit();
    self.cursor_shape.deinit();
    self.tablet.deinit();
    self.session_lock.deinit();
    self.session_lock_initialized = false;
    self.security_context.deinit();
    self.background_effect.deinit();
    self.content_type.deinit();
    self.single_pixel_buffer.deinit();
    self.xdg_output.deinit();
    self.xdg_output_initialized = false;
    render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| {
        std.debug.assert(self.removeRenderOutput(entry.id));
    }
    self.alpha_modifier.deinit();
    self.color_representation.deinit();
    self.color_management.deinit();
    self.outputs.deinit();
    self.render_outputs.deinit(allocator);
    self.window_transitions.deinit(allocator);
    self.workspace_transitions.deinit(allocator);
    self.routed_touches.deinit(allocator);
    self.routed_gestures.deinit(allocator);
    self.routed_buttons.deinit(allocator);
    self.routed_keys.deinit(allocator);
    self.seat.deinit();
    self.compositor.deinit();
    if (self.drm_device_initialized) self.drm_device.deinit();
    if (self.session_initialized) self.session.deinit();
    self.renderer.deinit();
    self.display.destroy();
    allocator.destroy(self);
}

fn addRenderOutput(
    self: *Self,
    io: std.Io,
    config: RenderOutputConfig,
) !RenderOutputId {
    const render_output = try self.allocator.create(RenderOutput);
    errdefer self.allocator.destroy(render_output);
    render_output.* = .{
        .server = self,
        .backend = undefined,
        .protocol_id = undefined,
        .color_description = .{},
        .output_calibration = null,
        .timer = null,
        .repaint_idle = null,
        .frame_callback_timer = null,
        .damage = Region.init(),
        .damage_rectangles = .empty,
        .sampled_surfaces = .empty,
        .sampled_surfaces_valid = false,
        .repaint_needed = false,
        .render_scheduled = false,
        .frame_callback_scheduled = false,
        .lock_frame_pending = false,
        .consecutive_output_busy_retries = 0,
        .frame_statistics = .{},
        .render_budget = .{},
        .request_started_nanoseconds = null,
        .frame_callback_deadline_nanoseconds = null,
        .repaint_deadline_nanoseconds = null,
        .repaint_target_vblank_nanoseconds = null,
        .pending_frame = null,
        .cursor_state = .software,
        .cursor_transition_committed = false,
    };
    errdefer render_output.damage.deinit();
    errdefer render_output.damage_rectangles.deinit(self.allocator);
    errdefer render_output.sampled_surfaces.deinit(self.allocator);
    try render_output.backend.init(
        self.allocator,
        io,
        self.display,
        config.size,
        config.scale,
        config.refresh_millihertz,
        config.kind,
        config.drm_output,
        backendListener(render_output),
        self.renderer.dmabufAccess(),
        self.renderer.offscreenAccess(),
    );
    errdefer render_output.backend.deinit();
    if (self.renderer.supportsColorManagement()) {
        render_output.color_description = render_output.backend.colorDescription();
        render_output.output_calibration = render_output.backend.outputCalibration();
    }
    const color_identity = try self.color_management.identityForDescription(
        render_output.color_description,
    );
    render_output.protocol_id = try self.outputs.add(.{
        .position = config.position,
        .size = render_output.backend.size(),
        .mode_size = render_output.backend.modeSize(),
        .physical_size = render_output.backend.physicalSize(),
        .mode_preferred = render_output.backend.modePreferred(),
        .refresh_millihertz = render_output.backend.refreshMillihertz(),
        .scale = render_output.backend.clientScale(),
        .preferred_scale = render_output.backend.renderScale(),
        .color_description = render_output.color_description,
        .color_identity = color_identity,
        .name = render_output.backend.name(config.name),
        .description = render_output.backend.description(config.description),
        .make = render_output.backend.make(config.make),
        .model = render_output.backend.model(config.model),
    });
    errdefer std.debug.assert(self.outputs.remove(render_output.protocol_id));
    errdefer stopRenderOutput(render_output);
    if (render_output.backend.repaintIntervalNanoseconds() != null or
        render_output.backend.supportsRepaintDelay())
    {
        render_output.timer = try self.display.getEventLoop().addTimer(
            *RenderOutput,
            handleRenderTimer,
            render_output,
        );
    }
    render_output.frame_callback_timer = try self.display.getEventLoop().addTimer(
        *RenderOutput,
        handleFrameCallbackTimer,
        render_output,
    );
    const id = try self.render_outputs.insert(self.allocator, render_output);
    errdefer std.debug.assert(self.render_outputs.remove(id) != null);
    if (self.workspace_initialized) try self.workspace.addOutput(render_output.protocol_id);
    errdefer if (self.workspace_initialized) self.workspace.removeOutput(render_output.protocol_id);
    if (self.window_manager_initialized) {
        try self.window_manager.outputAdded(render_output.protocol_id);
    }
    if (self.session_lock_initialized) self.session_lock.refreshOutputs();
    self.damageFullOutput(render_output);
    return id;
}

fn backendListener(render_output: *RenderOutput) OutputBackend.Listener {
    return .{
        .context = render_output,
        .ready = outputReady,
        .presented = outputPresented,
        .discarded = outputDiscarded,
        .close = closeOutput,
        .keyboard_available = keyboardAvailable,
        .keyboard_keymap = keyboardKeymap,
        .keyboard_enter = keyboardEnter,
        .keyboard_leave = keyboardLeave,
        .keyboard_key = keyboardKey,
        .keyboard_modifiers = keyboardModifiers,
        .keyboard_repeat_info = keyboardRepeatInfo,
        .pointer_available = pointerAvailable,
        .pointer_enter = pointerEnter,
        .pointer_leave = pointerLeave,
        .pointer_motion = pointerMotion,
        .pointer_relative_motion = pointerRelativeMotion,
        .pointer_button = pointerButton,
        .pointer_axis = pointerAxis,
        .pointer_frame = pointerFrame,
        .pointer_axis_source = pointerAxisSource,
        .pointer_axis_stop = pointerAxisStop,
        .pointer_axis_discrete = pointerAxisDiscrete,
        .pointer_axis_value120 = pointerAxisValue120,
        .pointer_axis_relative_direction = pointerAxisRelativeDirection,
        .touch_available = touchAvailable,
        .touch_down = touchDown,
        .touch_up = touchUp,
        .touch_motion = touchMotion,
        .touch_frame = touchFrame,
        .touch_cancel = touchCancel,
        .touch_shape = touchShape,
        .touch_orientation = touchOrientation,
    };
}

fn nativeInputListener(render_output: *RenderOutput) NativeInput.Listener {
    return .{
        .context = render_output,
        .close = closeOutput,
        .keyboard_available = keyboardAvailable,
        .keyboard_keymap = nativeKeyboardKeymap,
        .keyboard_enter = keyboardEnter,
        .keyboard_key = nativeKeyboardKey,
        .keyboard_modifiers = nativeKeyboardModifiers,
        .keyboard_repeat_info = nativeKeyboardRepeatInfo,
        .pointer_available = pointerAvailable,
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
        .touch_available = touchAvailable,
        .touch_down = nativeTouchDown,
        .touch_up = nativeTouchUp,
        .touch_motion = nativeTouchMotion,
        .touch_frame = nativeTouchFrame,
        .touch_cancel = nativeTouchCancel,
    };
}

fn inputDeviceAdded(context: *anyopaque, device: *InputManager.Device) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.configuration) |*configuration| {
        self.applyPhysicalInputConfiguration(device.physical_id, configuration.snapshot.input_rules);
    }
    const seat = &self.seat;
    if (device.device_type == .tablet) {
        const info = self.native_input.tabletInfo(device.id) orelse return;
        self.tablet.addTablet(
            device.id,
            device.physical_id,
            seat,
            device.name,
            info,
        ) catch return self.terminate();
    }
    if (device.device_type == .tablet_pad) {
        const info = self.native_input.tabletPadInfo(device.id) orelse return;
        self.tablet.addPad(device.id, device.physical_id, seat, info) catch return self.terminate();
    }
    self.refreshSeatCapabilities();
    if (device.device_type == .keyboard) self.prepareSeatKeyboard(seat, device.id);
}

fn inputDeviceRemoved(context: *anyopaque, device: *InputManager.Device) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (device.device_type == .keyboard) self.releaseDeviceKeys(device.id);
    if (device.device_type == .pointer) {
        self.releaseDeviceButtons(device.id);
        self.cancelDeviceGestures(device.id);
    }
    if (device.device_type == .tablet) self.tablet.removeTablet(device.id);
    if (device.device_type == .tablet_pad) self.tablet.removePad(device.id);
    if (device.device_type == .touch) self.cancelDeviceTouches(device.id);
    self.refreshSeatCapabilities();
    if (device.device_type == .keyboard) self.prepareAnySeatKeyboard();
}

fn seatForDevice(self: *Self, _: NativeInput.DeviceId) *Seat {
    return &self.seat;
}

fn refreshSeatCapabilities(self: *Self) void {
    var keyboard = false;
    var pointer = false;
    var touch = false;
    var devices = self.input_manager.deviceIterator();
    while (devices.next()) |device| {
        switch (device.device_type) {
            .keyboard => keyboard = true,
            .pointer => pointer = true,
            .touch => touch = true,
            .tablet, .tablet_pad => {},
        }
    }
    if (!pointer and !self.seat.hasVirtualPointers()) {
        self.pointer_constraints.deactivateAll();
        self.data_device.cancel();
    }
    self.seat.setKeyboardAvailable(keyboard);
    self.seat.setPointerAvailable(pointer);
    self.seat.setTouchAvailable(touch);
}

fn prepareAnySeatKeyboard(self: *Self) void {
    var devices = self.input_manager.deviceIterator();
    while (devices.next()) |device| {
        if (device.device_type != .keyboard) continue;
        self.prepareSeatKeyboard(&self.seat, device.id);
        return;
    }
    self.seat.setModifiers(0, 0, 0, 0);
}

fn prepareSeatKeyboard(self: *Self, seat: *Seat, id: NativeInput.DeviceId) void {
    const state = self.native_input.keyboardState(id) orelse return;
    const fd = self.native_input.duplicateKeyboardKeymapFd(id) catch {
        log.err("failed to duplicate keymap for input seat", .{});
        return self.terminate();
    } orelse return;
    seat.setKeymap(.xkb_v1, fd, state.keymap.size);
    if (self.native_input.deviceModifiers(id)) |modifiers| {
        seat.setModifiers(
            modifiers.depressed,
            modifiers.latched,
            modifiers.locked,
            modifiers.group,
        );
    }
}

fn removeRenderOutput(self: *Self, id: RenderOutputId) bool {
    const render_output = (self.render_outputs.get(id) orelse return false).*;
    finishWindowTransitionsForOutput(self, render_output.protocol_id);
    finishWorkspaceTransitionsForOutput(self, render_output.protocol_id);
    if (self.gamma_control_initialized) self.gamma_control.removeOutput(render_output.protocol_id);
    const removed = self.render_outputs.remove(id) orelse unreachable;
    std.debug.assert(removed == render_output);
    stopRenderOutput(render_output);
    const protocol_output = self.outputs.get(render_output.protocol_id).?;
    if (self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.removeOutput(render_output.protocol_id);
    }
    if (self.image_capture_source_initialized) {
        self.image_capture_source.removeOutput(render_output.protocol_id);
    }
    if (self.image_copy_capture_initialized) {
        self.image_copy_capture.removeOutput(render_output.protocol_id);
    }
    if (self.screencopy_initialized) self.screencopy.removeOutput(render_output.protocol_id);
    if (self.output_power_initialized) self.output_power.removeOutput(render_output.protocol_id);
    if (self.window_manager_initialized) {
        self.window_manager.outputRemoved(render_output.protocol_id) catch self.terminate();
    }
    if (self.layer_shell_initialized) self.layer_shell.outputRemoved(render_output.protocol_id);
    if (self.workspace_initialized) self.workspace.removeOutput(render_output.protocol_id);
    Surface.discardPresentation(self.compositor.surfaceStore(), protocol_output);
    Surface.clearFifoBarriersForOutput(self.compositor.surfaceStore(), protocol_output);
    if (self.xdg_output_initialized) self.xdg_output.removeOutput(protocol_output);
    self.color_management.removeOutput(protocol_output);
    std.debug.assert(self.outputs.remove(render_output.protocol_id));
    self.color_management.refreshPreferred();
    if (self.session_lock_initialized) {
        self.session_lock.outputRemoved(render_output.protocol_id);
        self.session_lock.refreshOutputs();
    }
    render_output.clearPendingFrame();
    render_output.backend.deinit();
    render_output.damage.deinit();
    render_output.damage_rectangles.deinit(self.allocator);
    render_output.sampled_surfaces.deinit(self.allocator);
    self.allocator.destroy(render_output);
    return true;
}

fn drmOutputAdded(context: *anyopaque, drm_output: *DrmOutput) void {
    const self: *Self = @ptrCast(@alignCast(context));
    var right: i32 = 0;
    var iterator = self.render_outputs.iterator();
    while (iterator.next()) |entry| {
        const output = entry.value.*;
        const protocol_output = self.outputs.get(output.protocol_id).?;
        const position = protocol_output.logicalPosition();
        const output_right = std.math.add(
            i32,
            position.x,
            @intCast(protocol_output.logicalSize().width),
        ) catch return self.terminate();
        right = @max(right, output_right);
    }
    drm_output.logical_x = right;
    drm_output.logical_y = 0;
    if (drm_output.enabled) {
        _ = self.addRenderOutput(self.native_input.io, .{
            .kind = .drm,
            .size = drm_output.size,
            .position = .{ .x = right },
            .name = "DRM",
            .description = "Keywork DRM output",
            .model = "drm-kms",
            .drm_output = drm_output,
        }) catch return self.terminate();
    }
    if (self.output_management_initialized) {
        self.output_management.addHead(drm_output) catch return self.terminate();
        if (self.configuration) |*configuration| {
            self.applyConfiguredOutputs(configuration.snapshot.output_rules, drm_output) catch |err| {
                log.warn("failed to apply configuration for hotplugged output {s}: {t}", .{
                    drm_output.name(), err,
                });
            };
        }
    }
    if (self.drm_lease_initialized) {
        self.drm_lease.addConnector(drm_output) catch return self.terminate();
    }
    requestRepaint(self);
}

fn drmOutputChanged(context: *anyopaque, drm_output: *DrmOutput) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const render_output = self.findDrmRenderOutput(drm_output) orelse return;
    self.refreshRenderOutputColorDescription(render_output.output) catch
        self.terminate();
}

fn findDrmRenderOutput(self: *Self, drm_output: *DrmOutput) ?struct {
    id: RenderOutputId,
    output: *RenderOutput,
} {
    var iterator = self.render_outputs.iterator();
    while (iterator.next()) |entry| {
        if (entry.value.*.backend.drmOutput() != drm_output) continue;
        return .{ .id = entry.id, .output = entry.value.* };
    }
    return null;
}

fn findProtocolRenderOutput(self: *Self, output_id: OutputLayout.Id) ?*RenderOutput {
    var iterator = self.render_outputs.iterator();
    while (iterator.next()) |entry| {
        if (std.meta.eql(entry.value.*.protocol_id, output_id)) return entry.value.*;
    }
    return null;
}

fn outputPowerState(context: *anyopaque, output_id: OutputLayout.Id) ?bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const render_output = self.findProtocolRenderOutput(output_id) orelse return null;
    const drm_output = render_output.backend.drmOutput() orelse return null;
    return drm_output.powered;
}

fn setOutputPowerState(context: *anyopaque, output_id: OutputLayout.Id, powered: bool) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const render_output = self.findProtocolRenderOutput(output_id) orelse return false;
    const drm_output = render_output.backend.drmOutput() orelse return false;
    self.drm_device.setOutputPowered(drm_output, powered) catch |err| {
        log.warn("failed to set output {s} power state: {t}", .{ drm_output.name(), err });
        return false;
    };
    if (!powered) render_output.repaint_needed = false;
    requestRepaint(self);
    if (!powered) self.session_lock.refreshSecurity();
    return true;
}

fn outputGammaSize(context: *anyopaque, output_id: OutputLayout.Id) ?u32 {
    const self: *Self = @ptrCast(@alignCast(context));
    const render_output = self.findProtocolRenderOutput(output_id) orelse return null;
    const drm_output = render_output.backend.drmOutput() orelse return null;
    return drm_output.gammaSize();
}

fn setOutputGamma(context: *anyopaque, output_id: OutputLayout.Id, table: []const u16) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const render_output = self.findProtocolRenderOutput(output_id) orelse return false;
    const drm_output = render_output.backend.drmOutput() orelse return false;
    drm_output.setGamma(table) catch |err| {
        log.warn("failed to set gamma ramps on {s}: {t}", .{ drm_output.name(), err });
        return false;
    };
    return true;
}

fn resetOutputGamma(context: *anyopaque, output_id: OutputLayout.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const render_output = self.findProtocolRenderOutput(output_id) orelse return;
    const drm_output = render_output.backend.drmOutput() orelse return;
    drm_output.resetGamma();
}

fn outputSecureWithoutFrame(context: *anyopaque, output_id: OutputLayout.Id) bool {
    return outputPowerState(context, output_id) == false;
}

fn setDrmOutputConfiguration(
    self: *Self,
    drm_output: *DrmOutput,
    position: Output.Position,
    scale: render.Scale,
) void {
    std.debug.assert(drmOutputGeometryValid(
        drm_output,
        drm_output.currentModeIndex(),
        position,
        scale,
    ));
    const position_changed = drm_output.logical_x != position.x or drm_output.logical_y != position.y;
    const scale_changed = drm_output.scale.numerator != scale.numerator;
    drm_output.logical_x = position.x;
    drm_output.logical_y = position.y;
    drm_output.scale = scale;
    const render_output = self.findDrmRenderOutput(drm_output) orelse return;
    const protocol_output = self.outputs.get(render_output.output.protocol_id).?;
    const old_logical_size = protocol_output.logicalSize();
    const mode_changed = protocol_output.configure(
        position,
        render_output.output.backend.size(),
        render_output.output.backend.modeSize(),
        drm_output.refreshMillihertz(),
        render_output.output.backend.modePreferred(),
        render_output.output.backend.clientScale(),
        render_output.output.backend.renderScale(),
    );
    const dimensions_changed = !std.meta.eql(old_logical_size, protocol_output.logicalSize());
    const logical_size = render_output.output.backend.size();
    log.info(
        "configured {s} at {d},{d}: logical {d}x{d}, scale {d}/{d}",
        .{
            drm_output.name(),
            position.x,
            position.y,
            logical_size.width,
            logical_size.height,
            scale.numerator,
            render.Scale.denominator,
        },
    );
    self.xdg_output.refresh(protocol_output);
    protocol_output.sendDone();
    self.window_manager.outputStateChanged(
        render_output.output.protocol_id,
        position_changed,
        dimensions_changed,
    );
    if ((scale_changed or mode_changed) and std.meta.eql(render_output.id, self.primary_render_output) and
        self.native_input_initialized)
    {
        self.native_input.retarget(
            render_output.output.backend.size(),
            nativeInputListener(render_output.output),
        );
    }
    if (position_changed or dimensions_changed) {
        self.layer_shell.refresh();
        self.session_lock.refreshOutputs();
    }
}

fn setHeadlessOutputMode(
    self: *Self,
    size: render.Size,
    scale: render.Scale,
) !void {
    const render_output = self.primaryRenderOutput();
    const protocol_output = self.outputs.get(render_output.protocol_id).?;
    const old_logical_size = protocol_output.logicalSize();
    if (!try render_output.backend.resizeHeadless(size, scale)) return;

    _ = protocol_output.configure(
        protocol_output.logicalPosition(),
        render_output.backend.size(),
        render_output.backend.modeSize(),
        render_output.backend.refreshMillihertz(),
        render_output.backend.modePreferred(),
        render_output.backend.clientScale(),
        render_output.backend.renderScale(),
    );
    const logical_size = protocol_output.logicalSize();
    const dimensions_changed = !std.meta.eql(old_logical_size, logical_size);
    self.xdg_output.refresh(protocol_output);
    protocol_output.sendDone();
    self.window_manager.outputStateChanged(
        render_output.protocol_id,
        false,
        dimensions_changed,
    );
    if (dimensions_changed) {
        self.layer_shell.refresh();
        self.session_lock.refreshOutputs();
    }
    if (self.output_management_initialized) {
        self.output_management.syncVirtualHead(
            protocol_output,
            render_output.backend.modeSize(),
            render_output.backend.refreshMillihertz(),
            render_output.backend.renderScale(),
        );
    }
    self.damageFullOutput(render_output);
    log.info(
        "configured headless output: mode {d}x{d}, logical {d}x{d}, scale {d}/{d}",
        .{
            size.width,
            size.height,
            logical_size.width,
            logical_size.height,
            scale.numerator,
            render.Scale.denominator,
        },
    );
}

fn enableDrmOutput(self: *Self, drm_output: *DrmOutput, position: Output.Position) !void {
    if (!drmOutputGeometryValid(
        drm_output,
        drm_output.currentModeIndex(),
        position,
        drm_output.scale,
    )) return error.InvalidOutputGeometry;
    if (drm_output.enabled) {
        self.setDrmOutputConfiguration(drm_output, position, drm_output.scale);
        return;
    }
    try self.drm_device.setOutputEnabled(drm_output, true);
    errdefer self.drm_device.setOutputEnabled(drm_output, false) catch {};
    drm_output.logical_x = position.x;
    drm_output.logical_y = position.y;
    _ = try self.addRenderOutput(self.native_input.io, .{
        .kind = .drm,
        .size = drm_output.size,
        .position = position,
        .name = "DRM",
        .description = "Keywork DRM output",
        .model = "drm-kms",
        .drm_output = drm_output,
    });
    requestRepaint(self);
}

fn disableDrmOutput(self: *Self, drm_output: *DrmOutput) !void {
    if (!drm_output.enabled) return;
    if (self.render_outputs.count <= 1) return error.LastEnabledOutput;
    const render_output = self.findDrmRenderOutput(drm_output) orelse
        return error.MissingRenderOutput;
    try self.drm_device.setOutputEnabled(drm_output, false);
    if (std.meta.eql(render_output.id, self.primary_render_output)) {
        self.replacePrimaryRenderOutput(render_output.id);
    }
    std.debug.assert(self.removeRenderOutput(render_output.id));
    requestRepaint(self);
}

fn replacePrimaryRenderOutput(self: *Self, removed_id: RenderOutputId) void {
    var iterator = self.render_outputs.iterator();
    while (iterator.next()) |entry| if (!std.meta.eql(entry.id, removed_id)) {
        self.primary_render_output = entry.id;
        const replacement = entry.value.*;
        self.fractional_scale.setDefaultOutput(replacement.protocol_id);
        self.xdg_shell.setDefaultOutput(replacement.protocol_id);
        self.layer_shell.setDefaultOutput(replacement.protocol_id);
        self.window_manager.setDefaultOutput(replacement.protocol_id);
        self.native_input.retarget(replacement.backend.size(), nativeInputListener(replacement));
        return;
    };
    unreachable;
}

fn drmOutputRemoving(context: *anyopaque, drm_output: *DrmOutput) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.drm_lease_initialized) self.drm_lease.removeConnector(drm_output);
    if (self.output_management_initialized) self.output_management.removeHead(drm_output);
    const render_output = self.findDrmRenderOutput(drm_output) orelse return;
    const id = render_output.id;
    if (self.render_outputs.count == 1) {
        var fallback: ?*DrmOutput = null;
        for (self.drm_device.outputs()) |candidate| {
            if (candidate != drm_output and !candidate.enabled and
                (!self.drm_lease_initialized or !self.drm_lease.outputLeased(candidate)))
            {
                fallback = candidate;
                break;
            }
        }
        if (fallback) |replacement| {
            self.enableDrmOutput(replacement, .{
                .x = replacement.logical_x,
                .y = replacement.logical_y,
            }) catch |err| switch (err) {
                error.InvalidOutputGeometry => {
                    log.warn(
                        "resetting unusable geometry while enabling fallback output {s}",
                        .{replacement.name()},
                    );
                    replacement.scale = .{};
                    self.enableDrmOutput(replacement, .{}) catch return self.terminate();
                },
                else => return self.terminate(),
            };
            if (self.output_management_initialized) self.output_management.syncHead(replacement);
        } else {
            if (self.native_input_initialized) {
                if (self.builtin_keybindings_initialized) self.builtin_keybindings.detachNativeInput();
                if (self.input_manager_initialized) self.input_manager.detachNativeInput();
                self.native_input.deinit();
                self.native_input_initialized = false;
            }
            std.debug.assert(self.removeRenderOutput(id));
            self.terminate();
            return;
        }
    }
    if (std.meta.eql(id, self.primary_render_output)) {
        self.replacePrimaryRenderOutput(id);
    }
    std.debug.assert(self.removeRenderOutput(id));
    requestRepaint(self);
}

fn applyOutputConfiguration(context: *anyopaque, changes: []const OutputManagement.Change) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    if (changes.len == 0) return false;
    return switch (changes[0].target) {
        .drm => self.applyDrmOutputChanges(changes),
        .virtual => self.applyVirtualOutputChanges(changes),
    };
}

fn testOutputConfiguration(context: *anyopaque, changes: []const OutputManagement.Change) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    if (changes.len == 0) return false;
    return switch (changes[0].target) {
        .drm => self.drmOutputChangesAvailable(changes),
        .virtual => self.virtualOutputChangesAvailable(changes),
    };
}

fn drmOutputChangesAvailable(self: *Self, changes: []const OutputManagement.Change) bool {
    if (self.drm_lease_initialized) for (changes) |change| {
        const output = switch (change.target) {
            .drm => |value| value,
            .virtual => return false,
        };
        if (self.drm_lease.outputLeased(output)) return false;
    };
    for (changes) |change| {
        const output = switch (change.target) {
            .drm => |value| value,
            .virtual => return false,
        };
        if (change.custom_mode != null) return false;
        if (change.enabled and !drmOutputGeometryValid(
            output,
            change.mode_index,
            .{ .x = change.x, .y = change.y },
            change.scale,
        )) return false;
    }
    return true;
}

fn applyDrmOutputChanges(self: *Self, changes: []const OutputManagement.Change) bool {
    if (!self.drmOutputChangesAvailable(changes)) return false;
    for (changes) |change| {
        const output = switch (change.target) {
            .drm => |value| value,
            .virtual => unreachable,
        };
        if (change.old_mode_index == change.mode_index) continue;
        self.drm_device.setOutputMode(output, change.mode_index) catch {
            rollbackOutputConfiguration(self, changes);
            return false;
        };
    }
    for (changes) |change| {
        const output = switch (change.target) {
            .drm => |value| value,
            .virtual => unreachable,
        };
        if (change.was_enabled or !change.enabled) continue;
        output.scale = change.scale;
        self.enableDrmOutput(output, .{ .x = change.x, .y = change.y }) catch {
            rollbackOutputConfiguration(self, changes);
            return false;
        };
    }

    for (changes) |change| {
        const output = switch (change.target) {
            .drm => |value| value,
            .virtual => unreachable,
        };
        if (change.enabled) self.setDrmOutputConfiguration(
            output,
            .{ .x = change.x, .y = change.y },
            change.scale,
        );
    }
    for (changes) |change| {
        const output = switch (change.target) {
            .drm => |value| value,
            .virtual => unreachable,
        };
        if (!change.was_enabled or change.enabled) continue;
        self.disableDrmOutput(output) catch {
            rollbackOutputConfiguration(self, changes);
            return false;
        };
    }
    for (changes) |change| {
        const output = switch (change.target) {
            .drm => |value| value,
            .virtual => unreachable,
        };
        if (change.enabled) continue;
        output.logical_x = change.x;
        output.logical_y = change.y;
        output.scale = change.scale;
    }
    requestRepaint(self);
    return true;
}

fn virtualOutputChangesAvailable(self: *Self, changes: []const OutputManagement.Change) bool {
    if (changes.len != 1) return false;
    const change = changes[0];
    const output = switch (change.target) {
        .virtual => |value| value,
        .drm => return false,
    };
    const render_output = self.primaryRenderOutput();
    if (self.outputs.get(render_output.protocol_id).? != output or
        !change.was_enabled or !change.enabled or change.old_mode_index != 0 or
        change.mode_index != 0 or change.x != change.old_x or change.y != change.old_y)
    {
        return false;
    }
    const size = if (change.custom_mode) |mode|
        render.Size{ .width = mode.width, .height = mode.height }
    else
        render_output.backend.modeSize();
    return ControlProtocol.validHeadlessOutputMode(
        size.width,
        size.height,
        change.scale.numerator,
    );
}

fn applyVirtualOutputChanges(self: *Self, changes: []const OutputManagement.Change) bool {
    if (!self.virtualOutputChangesAvailable(changes)) return false;
    const change = changes[0];
    const size = if (change.custom_mode) |mode|
        render.Size{ .width = mode.width, .height = mode.height }
    else
        self.primaryRenderOutput().backend.modeSize();
    self.setHeadlessOutputMode(size, change.scale) catch |err| {
        log.warn("failed to apply output-management headless mode: {t}", .{err});
        return false;
    };
    return true;
}

fn outputDeviceMatch(output: *const DrmOutput) Config.OutputDeviceMatch {
    return .{
        .name = output.name(),
        .make = output.make(),
        .model = output.model(),
        .serial = output.serial(),
    };
}

fn configuredOutputChange(
    output: *DrmOutput,
    settings: output_configuration.ResolvedSettings,
) !?OutputManagement.Change {
    if (settings.enabled and !drmOutputGeometryValid(
        output,
        settings.mode_index,
        .{ .x = settings.x, .y = settings.y },
        settings.scale,
    )) return error.InvalidOutputGeometry;
    if (settings.enabled == output.enabled and settings.mode_index == output.currentModeIndex() and
        settings.x == output.logical_x and settings.y == output.logical_y and
        settings.scale.numerator == output.scale.numerator) return null;
    return .{
        .target = .{ .drm = output },
        .was_enabled = output.enabled,
        .enabled = settings.enabled,
        .old_x = output.logical_x,
        .old_y = output.logical_y,
        .old_scale = output.scale,
        .old_mode_index = output.currentModeIndex(),
        .x = settings.x,
        .y = settings.y,
        .scale = settings.scale,
        .mode_index = settings.mode_index,
        .custom_mode = null,
    };
}

fn drmOutputGeometryValid(
    output: *const DrmOutput,
    mode_index: usize,
    position: Output.Position,
    scale: render.Scale,
) bool {
    const modes = output.availableModes();
    if (mode_index >= modes.len) return false;
    const logical_size = scale.logicalSize(modes[mode_index].size()) catch return false;
    return Output.logicalGeometryValid(position, logical_size);
}

fn applyConfiguredOutputs(self: *Self, rules: []const Config.OutputRule, only: ?*DrmOutput) !void {
    if (!self.drm_device_initialized) return;
    var changes: std.ArrayList(OutputManagement.Change) = .empty;
    defer changes.deinit(self.allocator);
    var profiles: std.ArrayList(PreparedIccProfile) = .empty;
    defer {
        for (profiles.items) |*profile| {
            if (profile.profile) |*value| value.deinit(self.allocator);
            if (profile.owned_path) |path| self.allocator.free(path);
        }
        profiles.deinit(self.allocator);
    }
    for (self.drm_device.outputs()) |output| {
        if (only != null and only.? != output) continue;
        const settings = try output_configuration.resolve(
            .{
                .enabled = output.enabled,
                .mode_index = output.currentModeIndex(),
                .x = output.logical_x,
                .y = output.logical_y,
                .scale = output.scale,
            },
            outputDeviceMatch(output),
            output.availableModes(),
            rules,
        ) orelse continue;
        if (try configuredOutputChange(output, settings)) |change| {
            try changes.append(self.allocator, change);
        }
        const requested = settings.icc_profile orelse continue;
        const path: ?[]const u8 = switch (requested) {
            .none => null,
            .path => |value| value,
        };
        if (path == null and output.iccProfilePath() == null) continue;
        var profile = if (path) |value|
            Icc.loadOutputProfile(
                self.allocator,
                value,
                output.nativeColorDescription().primaries,
            ) catch |err| {
                log.warn("failed to load ICC profile for {s} from {s}: {t}", .{
                    output.name(),
                    value,
                    err,
                });
                return err;
            }
        else
            null;
        errdefer if (profile) |*value| value.deinit(self.allocator);
        var owned_path = if (path) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_path) |value| self.allocator.free(value);
        try profiles.append(self.allocator, .{
            .output = output,
            .profile = profile,
            .owned_path = owned_path,
            .color_description = output.colorDescriptionForIccProfile(profile),
        });
        profile = null;
        owned_path = null;
    }
    if (self.renderer.supportsColorManagement()) {
        for (profiles.items) |*prepared| {
            prepared.color_identity = try self.color_management.identityForDescription(
                prepared.color_description,
            );
        }
    }
    if (changes.items.len != 0) {
        if (!self.applyDrmOutputChanges(changes.items)) return error.OutputConfigurationFailed;
        if (self.output_management_initialized) {
            for (changes.items) |change| self.output_management.syncHead(switch (change.target) {
                .drm => |output| output,
                .virtual => unreachable,
            });
        }
    }
    for (profiles.items) |*prepared| {
        const path = prepared.owned_path;
        prepared.owned_path = null;
        prepared.output.replaceIccProfile(prepared.profile, path);
        prepared.profile = null;
        if (self.findDrmRenderOutput(prepared.output)) |render_output| {
            if (self.renderer.supportsColorManagement()) {
                std.debug.assert(prepared.color_identity != 0);
                self.updateRenderOutputColorDescription(
                    render_output.output,
                    prepared.color_description,
                    prepared.color_identity,
                );
            }
        }
    }
}

fn rollbackOutputConfiguration(self: *Self, changes: []const OutputManagement.Change) void {
    // Restore previously enabled heads first so rolling back a newly enabled
    // head never violates the compositor's one-enabled-output invariant.
    for (changes) |change| {
        const output = switch (change.target) {
            .drm => |value| value,
            .virtual => unreachable,
        };
        if (!change.was_enabled or output.enabled) continue;
        output.scale = change.old_scale;
        self.enableDrmOutput(
            output,
            .{ .x = change.old_x, .y = change.old_y },
        ) catch return self.terminate();
    }
    for (changes) |change| {
        const output = switch (change.target) {
            .drm => |value| value,
            .virtual => unreachable,
        };
        if (output.currentModeIndex() == change.old_mode_index) continue;
        self.drm_device.setOutputMode(output, change.old_mode_index) catch
            return self.terminate();
    }
    for (changes) |change| {
        const output = switch (change.target) {
            .drm => |value| value,
            .virtual => unreachable,
        };
        if (change.was_enabled) self.setDrmOutputConfiguration(
            output,
            .{ .x = change.old_x, .y = change.old_y },
            change.old_scale,
        );
    }
    for (changes) |change| {
        const output = switch (change.target) {
            .drm => |value| value,
            .virtual => unreachable,
        };
        if (change.was_enabled or !output.enabled) continue;
        self.disableDrmOutput(output) catch return self.terminate();
    }
    for (changes) |change| {
        const output = switch (change.target) {
            .drm => |value| value,
            .virtual => unreachable,
        };
        if (output.enabled) continue;
        output.logical_x = change.old_x;
        output.logical_y = change.old_y;
        output.scale = change.old_scale;
    }
    requestRepaint(self);
}

fn openDrmLeaseDevice(context: *anyopaque) ?std.posix.fd_t {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.drm_device.openNonMasterFd() catch |err| {
        log.warn("failed to open non-master DRM lease device: {t}", .{err});
        return null;
    };
}

fn grantDrmLease(context: *anyopaque, outputs: []const *DrmOutput) ?DrmLease.Grant {
    const self: *Self = @ptrCast(@alignCast(context));
    var disabled: std.ArrayList(*DrmOutput) = .empty;
    defer disabled.deinit(self.allocator);
    disabled.ensureUnusedCapacity(self.allocator, outputs.len) catch return null;

    for (outputs) |output| {
        if (self.drm_device.outputLeased(output)) {
            restoreDrmLeaseOutputs(self, disabled.items);
            return null;
        }
        if (!output.enabled) continue;
        disabled.appendAssumeCapacity(output);
        self.disableDrmOutput(output) catch {
            _ = disabled.pop();
            restoreDrmLeaseOutputs(self, disabled.items);
            return null;
        };
        if (self.output_management_initialized) self.output_management.syncHead(output);
    }

    const lease = self.drm_device.createLease(outputs) catch {
        restoreDrmLeaseOutputs(self, disabled.items);
        return null;
    };
    return .{ .fd = lease.fd, .lessee_id = lease.lessee_id };
}

fn restoreDrmLeaseOutputs(self: *Self, outputs: []const *DrmOutput) void {
    var index = outputs.len;
    while (index > 0) {
        index -= 1;
        const output = outputs[index];
        self.enableDrmOutput(output, .{
            .x = output.logical_x,
            .y = output.logical_y,
        }) catch return self.terminate();
        if (self.output_management_initialized) self.output_management.syncHead(output);
    }
}

fn revokeDrmLease(context: *anyopaque, lessee_id: u32) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.drm_device.revokeLease(lessee_id);
}

fn drmDeviceActivated(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    var outputs = self.render_outputs.iterator();
    while (outputs.next()) |entry| {
        const render_output = entry.value.*;
        if (render_output.backend.drmOutput() == null) continue;
        self.refreshRenderOutputColorDescription(render_output) catch
            return self.terminate();
    }
    if (self.gamma_control_initialized) self.gamma_control.refreshOutputs();
    if (self.drm_lease_initialized) self.drm_lease.@"resume"();
}

fn refreshRenderOutputColorDescription(
    self: *Self,
    render_output: *RenderOutput,
) !void {
    if (!self.renderer.supportsColorManagement()) return;
    const description = render_output.backend.colorDescription();
    const identity = try self.color_management.identityForDescription(description);
    self.updateRenderOutputColorDescription(render_output, description, identity);
}

fn updateRenderOutputColorDescription(
    self: *Self,
    render_output: *RenderOutput,
    description: render.ColorDescription,
    identity: u64,
) void {
    std.debug.assert(self.renderer.supportsColorManagement());
    std.debug.assert(identity != 0);
    std.debug.assert(std.meta.eql(description, render_output.backend.colorDescription()));
    const calibration = render_output.backend.outputCalibration();
    const description_changed = !std.meta.eql(description, render_output.color_description);
    const calibration_changed = calibrationIdentity(calibration) !=
        calibrationIdentity(render_output.output_calibration);
    // A same-content profile reload preserves identity but replaces the
    // backend-owned value storage referenced by this snapshot.
    render_output.output_calibration = calibration;
    if (!description_changed and !calibration_changed) return;
    if (description_changed) {
        const output = self.outputs.get(render_output.protocol_id) orelse unreachable;
        self.color_management.updateOutputColorDescription(output, description, identity);
    }
    render_output.color_description = description;
    self.damageFullOutput(render_output);
}

fn calibrationIdentity(calibration: ?render.OutputCalibration) ?u64 {
    return if (calibration) |value| value.identity else null;
}

fn drmDeviceDeactivating(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.drm_lease_initialized) self.drm_lease.@"suspend"();
}

fn drmLeaseRevoked(context: *anyopaque, lessee_id: u32) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.drm_lease_initialized) self.drm_lease.leaseRevoked(lessee_id);
}

fn drmDeviceFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.terminate();
}

fn stopRenderOutput(render_output: *RenderOutput) void {
    _ = render_output.backend.disableShapeCursor();
    render_output.cursor_state = .software;
    render_output.cursor_transition_committed = false;
    if (render_output.timer) |timer| {
        timer.remove();
        render_output.timer = null;
    }
    if (render_output.repaint_idle) |idle| {
        idle.remove();
        render_output.repaint_idle = null;
    }
    if (render_output.frame_callback_timer) |timer| {
        timer.remove();
        render_output.frame_callback_timer = null;
    }
    render_output.render_scheduled = false;
    render_output.frame_callback_scheduled = false;
}

pub fn listen(self: *Self) ![:0]const u8 {
    std.debug.assert(!self.listening);
    const socket_name = try self.display.addSocketAuto(&self.socket_buffer);
    self.listening = true;
    return socket_name;
}

pub fn listenControl(self: *Self, runtime_directory: []const u8) !void {
    std.debug.assert(self.listening and !self.control_initialized);
    try self.control.init(
        self.allocator,
        self.io,
        self.eventLoop(),
        .{
            .context = self,
            .execute = executeControlCommand,
            .windows = controlWindows,
            .statistics = controlPerformanceStatistics,
            .reset_statistics = resetControlPerformanceStatistics,
            .set_unfocused_border = setControlUnfocusedBorder,
            .set_log_level = setControlLogLevel,
            .set_headless_output_mode = setControlHeadlessOutputMode,
            .reload = reloadControlConfiguration,
            .quit = quitControlSession,
        },
        runtime_directory,
    );
    self.control_initialized = true;
}

pub fn watchAppearance(self: *Self, runtime_directory: []const u8) void {
    std.debug.assert(!self.appearance_client_initialized);
    self.appearance_client.init(
        self.allocator,
        self.io,
        self.eventLoop(),
        .{ .context = self, .changed = appearanceChanged },
        runtime_directory,
    ) catch |err| {
        log.info("Prefer appearance service unavailable; using built-in palette: {t}", .{err});
        return;
    };
    self.appearance_client_initialized = true;
}

fn appearanceChanged(context: *anyopaque, preferences: AppearanceClient.Preferences) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.reduced_motion != preferences.reduced_motion) {
        self.reduced_motion = preferences.reduced_motion;
        if (self.reduced_motion) {
            finishAllWindowTransitions(self);
            finishAllWorkspaceTransitions(self);
        }
        requestRepaint(self);
    }
    const palette = theme.builtIn(preferences.scheme);
    if (!std.meta.eql(self.palette, palette)) {
        self.palette = palette;
        if (self.configuration) |*configuration| {
            self.applyGeneralConfiguration(configuration.snapshot.general);
        }
        requestRepaint(self);
    }
}

fn executeControlCommand(context: *anyopaque, command: Command) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.window_manager.execute(command);
}

fn controlWindows(
    context: *anyopaque,
    allocator: std.mem.Allocator,
) ![]ControlProtocol.Window {
    const self: *Self = @ptrCast(@alignCast(context));
    const snapshots = try self.window_manager.windowSnapshots(allocator);
    defer allocator.free(snapshots);

    const result = try allocator.alloc(ControlProtocol.Window, snapshots.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |window| allocator.free(window.id);
        allocator.free(result);
    }
    for (snapshots, result) |snapshot, *window| {
        window.* = .{
            .id = try std.fmt.allocPrint(allocator, "{x:0>8}:{x:0>8}", .{
                snapshot.id.generation,
                snapshot.id.index,
            }),
            .protocol = switch (snapshot.protocol) {
                .xdg_shell => .xdg_shell,
                .xwayland => .xwayland,
            },
            .title = snapshot.title,
            .appId = snapshot.app_id,
            .pid = if (snapshot.pid) |pid| pid else null,
            .rect = if (snapshot.rect) |rect| .{
                .x = rect.x,
                .y = rect.y,
                .width = rect.width,
                .height = rect.height,
            } else null,
            .output = snapshot.output_name,
            .workspace = snapshot.workspace,
            .focused = snapshot.focused,
            .visible = snapshot.visible,
            .floating = snapshot.floating,
            .fullscreen = snapshot.fullscreen,
            .maximized = snapshot.maximized,
            .minimized = snapshot.minimized,
        };
        initialized += 1;
    }
    return result;
}

fn wireInteger(value: u64) i64 {
    return @intCast(@min(value, @as(u64, std.math.maxInt(i64))));
}

fn controlPerformanceStatistics(
    context: *anyopaque,
    allocator: std.mem.Allocator,
) !ControlProtocol.PerformanceStatistics {
    const self: *Self = @ptrCast(@alignCast(context));
    self.collectGpuTimings();
    const result = try allocator.alloc(ControlProtocol.OutputStatistics, self.render_outputs.count);
    var index: usize = 0;
    var outputs = self.render_outputs.iterator();
    while (outputs.next()) |entry| : (index += 1) {
        const render_output = entry.value.*;
        const protocol_output = self.outputs.get(render_output.protocol_id).?;
        result[index] = render_output.frame_statistics.snapshot(
            protocol_output.name(),
            render_output.backend.modeSize(),
            render_output.backend.refreshMillihertz(),
            self.renderer.workingFormat(),
            render_output.render_budget.budgetNanoseconds(),
        );
    }
    const renderer_statistics = self.renderer.resourceStatistics();
    const screencopy_buffers = self.screencopy.destinationBufferCount();
    const image_copy_buffers = self.image_copy_capture.destinationBufferCount();
    return .{
        .outputs = result,
        .resources = .{
            .rendererTargets = wireInteger(@intCast(renderer_statistics.targets)),
            .pixelRendererTargets = wireInteger(@intCast(renderer_statistics.pixel_targets)),
            .offscreenRendererTargets = wireInteger(@intCast(renderer_statistics.offscreen_targets)),
            .dmabufRendererTargets = wireInteger(@intCast(renderer_statistics.dmabuf_targets)),
            .cachedTextures = wireInteger(@intCast(renderer_statistics.cached_textures)),
            .importedTextures = wireInteger(@intCast(renderer_statistics.imported_textures)),
            .pendingTextures = wireInteger(@intCast(renderer_statistics.pending_textures)),
            .pendingGpuSubmissions = wireInteger(@intCast(renderer_statistics.pending_gpu_submissions)),
            .pendingGpuTimings = wireInteger(@intCast(renderer_statistics.pending_gpu_timings)),
            .gpuTimingQueueHighWater = wireInteger(@intCast(
                renderer_statistics.gpu_timing_queue_high_water,
            )),
            .gpuTimingDrops = wireInteger(renderer_statistics.gpu_timing_drops),
            .calibrationTextures = wireInteger(@intCast(renderer_statistics.calibration_textures)),
            .videoGraphicsPipelines = wireInteger(@intCast(renderer_statistics.video_graphics_pipelines)),
            .blurScratchImages = wireInteger(@intCast(renderer_statistics.blur_scratch_images)),
            .backdropCacheImages = wireInteger(@intCast(renderer_statistics.backdrop_cache_images)),
            .mappedBufferCapacityBytes = wireInteger(@intCast(renderer_statistics.mapped_buffer_capacity_bytes)),
            .linuxDmabufBuffers = wireInteger(@intCast(self.linux_dmabuf.bufferCount())),
            .screencopyFrames = wireInteger(@intCast(self.screencopy.frameCount())),
            .imageCopyCaptureSessions = wireInteger(@intCast(self.image_copy_capture.sessionCount())),
            .imageCopyCaptureFrames = wireInteger(@intCast(self.image_copy_capture.frameCount())),
            .captureBuffers = wireInteger(@intCast(screencopy_buffers +| image_copy_buffers)),
            .gpuSubmissionOverlapFrames = wireInteger(
                @intCast(renderer_statistics.submission_overlap_frames),
            ),
            .gpuSubmissionSlotWaits = wireInteger(
                @intCast(renderer_statistics.submission_slot_waits),
            ),
            .gpuSubmissionSlotWaitMicroseconds = wireInteger(@intCast(
                renderer_statistics.submission_slot_wait_nanoseconds / std.time.ns_per_us,
            )),
        },
    };
}

fn resetControlPerformanceStatistics(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    var outputs = self.render_outputs.iterator();
    while (outputs.next()) |entry| entry.value.*.frame_statistics.reset();
    self.renderer.discardGpuTimings();
    self.renderer.resetStatistics();
}

fn outputStatisticsTag(id: OutputLayout.Id) u64 {
    return @as(u64, id.generation) << 32 | id.index;
}

fn outputStatisticsId(tag: u64) OutputLayout.Id {
    return .{
        .index = @truncate(tag),
        .generation = @truncate(tag >> 32),
    };
}

fn surfaceSampleTag(id: Surface.Id) u64 {
    return @as(u64, id.generation) << 32 | id.index;
}

fn setControlLogLevel(_: *anyopaque, level: ControlProtocol.LogLevel) void {
    Logging.setLevel(level);
    log.info("log level set to {s}", .{@tagName(level)});
}

fn setControlUnfocusedBorder(context: *anyopaque, border: ControlProtocol.Border) void {
    const self: *Self = @ptrCast(@alignCast(context));
    std.debug.assert(ControlProtocol.validBorder(border));
    const configuration = if (self.configuration) |*value| value else unreachable;
    const general = &configuration.snapshot.general;
    general.unfocused_border_width = @intCast(border.width);
    general.unfocused_border_color = .{
        .red = @intCast(border.color.red),
        .green = @intCast(border.color.green),
        .blue = @intCast(border.color.blue),
        .alpha = @intCast(border.color.alpha),
    };
    self.applyWindowBorders(general.*);
}

fn setControlHeadlessOutputMode(
    context: *anyopaque,
    width: u32,
    height: u32,
    scale: u32,
) ControlProtocol.HeadlessOutputModeResult {
    const self: *Self = @ptrCast(@alignCast(context));
    self.setHeadlessOutputMode(
        .{ .width = width, .height = height },
        .{ .numerator = scale },
    ) catch |err| {
        if (err == error.UnsupportedOutputBackend) return .unsupported;
        log.warn("failed to configure headless output: {t}", .{err});
        return .failed;
    };
    return .applied;
}

fn collectGpuTimings(self: *Self) void {
    while (self.renderer.takeGpuTiming()) |timing| {
        const render_output = self.findProtocolRenderOutput(
            outputStatisticsId(timing.tag),
        ) orelse continue;
        render_output.frame_statistics.addGpuExecution(timing);
    }
}

fn reloadControlConfiguration(context: *anyopaque) ?[]const u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    self.reloadConfiguration() catch |err| {
        if (self.configuration) |*configuration| {
            if (configuration.failureMessage()) |message| return message;
        }
        return @errorName(err);
    };
    return null;
}

fn quitControlSession(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.terminate();
}

pub fn setLauncher(self: *Self, launcher: *Launcher) void {
    if (self.builtin_keybindings_initialized) self.builtin_keybindings.setLauncher(launcher);
}

pub fn setConfiguration(self: *Self, configuration: *Config.Store) void {
    std.debug.assert(self.configuration == null);
    self.configuration = configuration.*;
    configuration.* = undefined;
    self.applyConfiguredOutputs(self.configuration.?.snapshot.output_rules, null) catch |err| {
        log.warn("failed to apply configured outputs; preserving default layout: {t}", .{err});
    };
    self.applyGeneralConfiguration(self.configuration.?.snapshot.general);
    self.applyInputConfiguration(self.configuration.?.snapshot.input_rules);
    if (self.builtin_keybindings_initialized) {
        self.builtin_keybindings.setConfiguredBindings(self.configuration.?.snapshot.bindings);
    }
}

pub fn reloadConfiguration(self: *Self) !void {
    const configuration = if (self.configuration) |*value| value else return error.ConfigurationUnavailable;
    var replacement = try configuration.loadSnapshot();
    errdefer replacement.deinit();
    try self.applyConfiguredOutputs(replacement.output_rules, null);
    self.applyGeneralConfiguration(replacement.general);
    self.applyInputConfiguration(replacement.input_rules);
    if (self.builtin_keybindings_initialized) {
        self.builtin_keybindings.setConfiguredBindings(replacement.bindings);
    }
    var previous = configuration.snapshot;
    configuration.snapshot = replacement;
    previous.deinit();
    log.info("configuration reloaded", .{});
}

fn applyGeneralConfiguration(self: *Self, general: Config.GeneralSettings) void {
    self.window_manager.setFocusFollowsMouse(general.focus_follows_mouse);
    self.window_manager.setGaps(general.inner_gap, general.outer_gap);
    const effects = configuredWindowEffects(general, self.palette);
    self.window_manager.setWindowEffects(effects);
    self.applyWindowBorders(general);
}

const Elevation = enum {
    shadow8,
    shadow16,
    shadow28,
    shadow64,
};

const ElevationMetrics = struct {
    ambient_blur_radius: u32,
    key_offset_y: i32,
    key_blur_radius: u32,
};

const ShadowColors = struct {
    ambient: Config.Color,
    key: Config.Color,
};

fn configuredWindowEffects(
    general: Config.GeneralSettings,
    palette: theme.Palette,
) WindowManager.WindowEffects {
    const normal_colors = configuredShadowColors(palette, general.shadow_color);
    const focused_colors = configuredShadowColors(
        palette,
        general.focused_shadow_color orelse general.shadow_color,
    );
    return .{
        .tiled = windowEffects(general, .shadow8, normal_colors),
        .tiled_focused = windowEffects(general, .shadow16, focused_colors),
        .floating = windowEffects(general, .shadow28, normal_colors),
        .floating_focused = windowEffects(general, .shadow64, focused_colors),
    };
}

fn configuredShadowColors(
    palette: theme.Palette,
    key_override: ?Config.Color,
) ShadowColors {
    const key = key_override orelse palette.shadow_key;
    if (key_override == null) return .{
        .ambient = palette.shadow_ambient,
        .key = key,
    };
    var ambient = key;
    ambient.alpha = @intCast((@as(u16, key.alpha) * 6 + 3) / 7);
    return .{ .ambient = ambient, .key = key };
}

fn elevationMetrics(elevation: Elevation) ElevationMetrics {
    return switch (elevation) {
        .shadow8 => .{ .ambient_blur_radius = 2, .key_offset_y = 4, .key_blur_radius = 8 },
        .shadow16 => .{ .ambient_blur_radius = 2, .key_offset_y = 8, .key_blur_radius = 16 },
        .shadow28 => .{ .ambient_blur_radius = 8, .key_offset_y = 14, .key_blur_radius = 28 },
        .shadow64 => .{ .ambient_blur_radius = 8, .key_offset_y = 32, .key_blur_radius = 64 },
    };
}

fn windowEffects(
    general: Config.GeneralSettings,
    elevation: Elevation,
    colors: ShadowColors,
) Scene.Effects {
    const metrics = elevationMetrics(elevation);
    return .{
        .corner_radius = general.corner_radius,
        .ambient_shadow = if (general.shadow_enabled) .{
            .blur_radius = metrics.ambient_blur_radius,
            .color = renderColor(colors.ambient),
        } else null,
        .key_shadow = if (general.shadow_enabled) .{
            .offset = .{ .y = metrics.key_offset_y },
            .blur_radius = general.shadow_blur_radius orelse metrics.key_blur_radius,
            .color = renderColor(colors.key),
        } else null,
    };
}

fn applyWindowBorders(self: *Self, general: Config.GeneralSettings) void {
    const unfocused = windowBorder(
        general.unfocused_border_width,
        general.unfocused_border_color orelse self.palette.unfocused_border,
    );
    const focused = windowBorder(
        general.focused_border_width,
        general.focused_border_color orelse self.palette.focused_border,
    );
    self.window_manager.setWindowBorders(unfocused, focused);
}

fn windowBorder(width: u32, color: Config.Color) ?Scene.Borders {
    if (width == 0) return null;
    return .{
        .edges = .{ .top = true, .bottom = true, .left = true, .right = true },
        .width = width,
        .color = renderColor(color),
    };
}

fn renderColor(color: Config.Color) render.Color {
    return render.Color.rgba(color.red, color.green, color.blue, color.alpha);
}

fn applyInputConfiguration(self: *Self, rules: []const Config.InputRule) void {
    if (!self.native_input_initialized or !self.input_manager_initialized) return;
    var devices = self.input_manager.deviceIterator();
    while (devices.next()) |device| {
        var earlier = false;
        var candidates = self.input_manager.deviceIterator();
        while (candidates.next()) |candidate| {
            if (candidate.physical_id == device.physical_id and candidate.id < device.id) {
                earlier = true;
                break;
            }
        }
        if (!earlier) self.applyPhysicalInputConfiguration(device.physical_id, rules);
    }
}

fn applyPhysicalInputConfiguration(
    self: *Self,
    physical_id: NativeInput.PhysicalDeviceId,
    rules: []const Config.InputRule,
) void {
    if (!self.native_input_initialized or !self.input_manager_initialized) return;
    var representative: ?*InputManager.Device = null;
    var devices = self.input_manager.deviceIterator();
    while (devices.next()) |device| {
        if (device.physical_id != physical_id) continue;
        representative = device;
        break;
    }
    const device = representative orelse return;
    const capabilities = self.native_input.deviceCapabilities(device.id) orelse return;
    const defaults = self.native_input.deviceConfig(device.id) orelse return;
    const matched_device: Config.InputDeviceMatch = .{
        .name = device.name,
        .vendor = device.vendor,
        .product = device.product,
        .keyboard = capabilities.keyboard,
        .pointer = capabilities.pointer,
        .touchpad = capabilities.pointer and defaults.tap_finger_count > 0,
        .touch = capabilities.touch,
        .tablet = capabilities.tablet,
        .tablet_pad = capabilities.tablet_pad,
    };
    const effective = input_configuration.resolve(defaults, matched_device, rules);
    self.applyEffectiveInputSettings(device, effective);
}

fn applyEffectiveInputSettings(
    self: *Self,
    device: *InputManager.Device,
    settings: input_configuration.EffectiveSettings,
) void {
    reportInputStatus(device.name, "send-events", self.native_input.setSendEvents(device.id, settings.send_events));
    if (settings.tap) |value| reportInputStatus(device.name, "tap", self.native_input.setTap(device.id, value));
    if (settings.tap_button_map) |value| reportInputStatus(device.name, "tap-button-map", self.native_input.setTapButtonMap(device.id, value));
    if (settings.drag) |value| reportInputStatus(device.name, "drag", self.native_input.setDrag(device.id, value));
    if (settings.drag_lock) |value| reportInputStatus(device.name, "drag-lock", self.native_input.setDragLock(device.id, value));
    if (settings.three_finger_drag) |value| reportInputStatus(device.name, "three-finger-drag", self.native_input.setThreeFingerDrag(device.id, value));
    if (settings.accel_profile) |value| reportInputStatus(device.name, "accel-profile", self.native_input.setAccelProfile(device.id, value));
    if (settings.accel_speed) |value| reportInputStatus(device.name, "accel-speed", self.native_input.setAccelSpeed(device.id, value));
    if (settings.natural_scroll) |value| reportInputStatus(device.name, "natural-scroll", self.native_input.setNaturalScroll(device.id, value));
    if (settings.left_handed) |value| reportInputStatus(device.name, "left-handed", self.native_input.setLeftHanded(device.id, value));
    if (settings.click_method) |value| reportInputStatus(device.name, "click-method", self.native_input.setClickMethod(device.id, value));
    if (settings.clickfinger_button_map) |value| reportInputStatus(device.name, "clickfinger-button-map", self.native_input.setClickfingerButtonMap(device.id, value));
    if (settings.middle_emulation) |value| reportInputStatus(device.name, "middle-emulation", self.native_input.setMiddleEmulation(device.id, value));
    if (settings.scroll_method) |value| reportInputStatus(device.name, "scroll-method", self.native_input.setScrollMethod(device.id, value));
    if (settings.scroll_button) |value| reportInputStatus(device.name, "scroll-button", self.native_input.setScrollButton(device.id, value));
    if (settings.scroll_button_lock) |value| reportInputStatus(device.name, "scroll-button-lock", self.native_input.setScrollButtonLock(device.id, value));
    if (settings.disable_while_typing) |value| reportInputStatus(device.name, "disable-while-typing", self.native_input.setDwt(device.id, value));
    if (settings.disable_while_trackpointing) |value| reportInputStatus(device.name, "disable-while-trackpointing", self.native_input.setDwtp(device.id, value));
    if (settings.rotation) |value| reportInputStatus(device.name, "rotation", self.native_input.setRotation(device.id, value));

    var devices = self.input_manager.deviceIterator();
    while (devices.next()) |logical_device| {
        if (logical_device.physical_id != device.physical_id) continue;
        switch (logical_device.device_type) {
            .keyboard => self.native_input.setDeviceRepeatInfo(logical_device.id, settings.repeat_rate, settings.repeat_delay),
            .pointer => self.native_input.setDeviceScrollFactor(logical_device.id, settings.scroll_factor),
            .touch, .tablet, .tablet_pad => {},
        }
    }
}

fn reportInputStatus(device_name: []const u8, setting_name: []const u8, status: ?NativeInput.Status) void {
    const result = status orelse {
        log.warn("input device {s} disappeared while applying {s}", .{ device_name, setting_name });
        return;
    };
    switch (result) {
        .success => {},
        .unsupported => log.warn("input setting {s} is unsupported by {s}", .{ setting_name, device_name }),
        .invalid => log.warn("input setting {s} was rejected by {s}", .{ setting_name, device_name }),
    }
}

/// Copies the listener and retains its context until replacement or deinit.
pub fn setXwaylandDisplayListener(self: *Self, listener: XwaylandDisplayListener) void {
    self.xwayland_display_listener = listener;
}

pub fn startXwayland(
    self: *Self,
    environ_map: *std.process.Environ.Map,
) ?[]const u8 {
    self.xwayland_server.start(environ_map) catch |err| {
        log.warn("Xwayland is unavailable: {t}", .{err});
        return null;
    };
    if (self.xwayland_display_listener) |listener|
        listener.available(listener.context, self.xwayland_server.displayName());
    return self.xwayland_server.displayName();
}

pub fn eventLoop(self: *Self) *wl.EventLoop {
    return self.display.getEventLoop();
}

pub fn run(self: *Self) void {
    std.debug.assert(self.listening);
    std.debug.assert(self.configuration != null);
    self.display.run();
}

pub fn terminate(self: *Self) void {
    self.display.terminate();
}

noinline fn requestRepaint(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    log.debug("full repaint requested by 0x{x}", .{@returnAddress()});
    self.refreshIdleInhibition();
    if (self.image_copy_capture_initialized) self.image_copy_capture.refreshCursors();
    var render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| {
        const render_output = entry.value.*;
        if (!render_output.backend.powered()) {
            render_output.repaint_needed = false;
            render_output.damage.clear();
            continue;
        }
        self.damageFullOutput(render_output);
    }
}

fn cursorChanged(context: *anyopaque, old: ?Seat.CursorInfo, new: ?Seat.CursorInfo) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.refreshIdleInhibition();
    if (self.image_copy_capture_initialized) self.image_copy_capture.refreshCursors();
    var outputs = self.render_outputs.iterator();
    while (outputs.next()) |entry| {
        const output = entry.value.*;
        self.updateOutputCursor(output, old, new);
    }
}

fn shapeCursorForOutput(self: *Self, output: *RenderOutput, info: ?Seat.CursorInfo) ?OutputBackend.ShapeCursor {
    if (self.data_device.iconInfo() != null or output.output_calibration != null) return null;
    const cursor = info orelse return null;
    const shape = switch (cursor) {
        .shape => |shape| shape,
        .surface => return null,
    };
    const bounds = self.cursorBounds(cursor) orelse return null;
    if (bounds.intersection(self.outputs.get(output.protocol_id).?.logicalRect()) == null) return null;
    const source = shape.buffer.source_cache orelse return null;
    const image = self.cursor_shape.outputCursorImage(
        source,
        output.backend.renderScale(),
    ) orelse return null;
    const hardware: OutputBackend.ShapeCursor = .{
        .buffer = image.buffer,
        .size = image.size,
        .pointer_x = shape.x +| image.logical_hotspot_x,
        .pointer_y = shape.y +| image.logical_hotspot_y,
        .hotspot_x = image.hotspot_x,
        .hotspot_y = image.hotspot_y,
    };
    return if (output.backend.canUseShapeCursor(hardware)) hardware else null;
}

fn addOutputCursorDamage(self: *Self, output: *RenderOutput, info: ?Seat.CursorInfo) bool {
    const cursor = info orelse return false;
    const bounds = self.cursorBounds(cursor) orelse {
        const size = output.backend.modeSize();
        output.damage.setRectangle(0, 0, size.width, size.height);
        return true;
    };
    const output_rect = self.outputs.get(output.protocol_id).?.logicalRect();
    const intersection = bounds.intersection(output_rect) orelse return false;
    const physical = damage_geometry.scaleRect(.{
        .x = intersection.x -| output_rect.x,
        .y = intersection.y -| output_rect.y,
        .width = intersection.width,
        .height = intersection.height,
    }, output.backend.renderScale(), output.backend.modeSize()) orelse return false;
    output.damage.add(physical.x, physical.y, @intCast(physical.width), @intCast(physical.height)) catch {
        const size = output.backend.modeSize();
        output.damage.setRectangle(0, 0, size.width, size.height);
    };
    return true;
}

fn damageOutputCursor(self: *Self, output: *RenderOutput, info: ?Seat.CursorInfo) void {
    if (!self.addOutputCursorDamage(output, info)) return;
    output.requestFrame();
    self.scheduleRepaint(output);
}

fn cursorIntersectsOutput(self: *Self, output: *RenderOutput, info: ?Seat.CursorInfo) bool {
    const cursor = info orelse return false;
    const bounds = self.cursorBounds(cursor) orelse return true;
    return bounds.intersection(self.outputs.get(output.protocol_id).?.logicalRect()) != null;
}

fn updateOutputCursor(self: *Self, output: *RenderOutput, old: ?Seat.CursorInfo, new: ?Seat.CursorInfo) void {
    if (!output.backend.powered()) return;
    const eligible = self.shapeCursorForOutput(output, new);
    switch (output.cursor_state) {
        .software => if (eligible) |shape| {
            if (self.cursorIntersectsOutput(output, old)) {
                self.damageOutputCursor(output, old);
                output.cursor_state = .activating;
                output.cursor_transition_committed = false;
            } else if (output.backend.setShapeCursor(shape)) {
                output.cursor_state = .hardware;
            } else self.damageOutputCursor(output, new);
        } else {
            self.damageOutputCursor(output, old);
            self.damageOutputCursor(output, new);
        },
        .activating => if (eligible == null) {
            if (!output.cursor_transition_committed) {
                output.cursor_state = .software;
                self.damageOutputCursor(output, new);
            }
        },
        .hardware => if (eligible) |shape| {
            if (!output.backend.setShapeCursor(shape)) {
                output.cursor_state = if (output.backend.shapeCursorActive()) .deactivating else .software;
                output.cursor_transition_committed = false;
                self.damageOutputCursor(output, new);
            }
        } else if (!self.cursorIntersectsOutput(output, new)) {
            if (output.backend.disableShapeCursor()) output.cursor_state = .software else {
                output.cursor_state = .deactivating;
                output.cursor_transition_committed = false;
                self.damageOutputCursor(output, old);
            }
        } else {
            output.cursor_state = .deactivating;
            output.cursor_transition_committed = false;
            self.damageOutputCursor(output, new);
        },
        .deactivating => {
            self.damageOutputCursor(output, old);
            self.damageOutputCursor(output, new);
        },
    }
}

fn reconcileOutputCursors(self: *Self) void {
    const cursor = self.seatCursorInfo(&self.seat, self.session_lock.isLocked());
    var outputs = self.render_outputs.iterator();
    while (outputs.next()) |entry| self.updateOutputCursor(entry.value.*, cursor, cursor);
}

fn prepareOutputCursorFrame(
    self: *Self,
    output: *RenderOutput,
    force_software_cursor: bool,
) void {
    if ((output.cursor_state == .hardware or output.cursor_state == .deactivating) and
        !output.backend.shapeCursorActive())
    {
        output.cursor_state = .software;
        output.cursor_transition_committed = false;
        _ = self.addOutputCursorDamage(
            output,
            self.seatCursorInfo(&self.seat, self.session_lock.isLocked()),
        );
    }

    const cursor = self.seatCursorInfo(&self.seat, self.session_lock.isLocked());
    if (force_software_cursor) {
        switch (output.cursor_state) {
            .software, .deactivating => {},
            .activating => {
                output.cursor_state = if (output.backend.shapeCursorActive())
                    .deactivating
                else
                    .software;
                output.cursor_transition_committed = false;
                _ = self.addOutputCursorDamage(output, cursor);
            },
            .hardware => {
                output.cursor_state = .deactivating;
                output.cursor_transition_committed = false;
                _ = self.addOutputCursorDamage(output, cursor);
            },
        }
        return;
    }
    const eligible = self.shapeCursorForOutput(output, cursor);
    switch (output.cursor_state) {
        .software => {},
        .activating => if (eligible == null and !output.cursor_transition_committed) {
            output.cursor_state = .software;
            _ = self.addOutputCursorDamage(output, cursor);
        },
        .hardware => if (eligible) |shape| {
            if (!output.backend.setShapeCursor(shape)) {
                output.cursor_state = if (output.backend.shapeCursorActive()) .deactivating else .software;
                output.cursor_transition_committed = false;
                _ = self.addOutputCursorDamage(output, cursor);
            }
        } else if (self.cursorIntersectsOutput(output, cursor)) {
            output.cursor_state = .deactivating;
            output.cursor_transition_committed = false;
            _ = self.addOutputCursorDamage(output, cursor);
        } else if (output.backend.disableShapeCursor()) {
            output.cursor_state = .software;
        } else {
            output.cursor_state = .deactivating;
            output.cursor_transition_committed = false;
            const size = output.backend.modeSize();
            output.damage.setRectangle(0, 0, size.width, size.height);
        },
        .deactivating => {},
    }
}

fn scheduleCursorFallbackAfterColorChange(self: *Self, output: *RenderOutput) void {
    if (output.cursor_state != .hardware) return;
    const cursor = self.seatCursorInfo(&self.seat, self.session_lock.isLocked());
    if (self.shapeCursorForOutput(output, cursor) != null) return;
    self.damageOutputCursor(output, cursor);
}

fn surfaceChanged(context: *anyopaque, surface_id: Surface.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const surfaces = self.compositor.surfaceStore();
    const root = self.subcompositor.rootSurface(surface_id);
    markWindowTransitionTargetDirty(self, root);
    const root_position = self.scene.surfacePosition(root) orelse return requestRepaint(self);
    // Subsurface commits bypass the Scene commit path that filters hidden roots.
    if (!self.scene.surfaceMapped(root)) return;
    if (!Surface.currentDamagePrecise(surfaces, surface_id)) return requestRepaint(self);
    const offset = self.subcompositor.surfaceOffset(surface_id);
    const damage = Surface.currentDamage(surfaces, surface_id) orelse
        return requestRepaint(self);
    if (damage.isEmpty()) {
        if (Logging.enabled(.debug)) {
            const resource = Surface.resourceFor(surfaces, surface_id) orelse return;
            log.debug(
                "surface commit has no damage: pid={} surface={}:{} root={}:{}",
                .{
                    resource.getClient().getCredentials().pid,
                    surface_id.index,
                    surface_id.generation,
                    root.index,
                    root.generation,
                },
            );
        }
        self.scheduleSurfaceFrameCallback(surface_id);
        return;
    }

    var rectangles = damage.rectangleIterator();
    while (rectangles.next()) |rectangle| {
        const global: render.Rect = .{
            .x = root_position.x +| offset.x +| rectangle.x,
            .y = root_position.y +| offset.y +| rectangle.y,
            .width = rectangle.width,
            .height = rectangle.height,
        };
        if (Logging.enabled(.debug)) {
            const resource = Surface.resourceFor(surfaces, surface_id) orelse return;
            log.debug(
                "surface damage: pid={} surface={}:{} root={}:{} local={},{},{}x{} global={},{},{}x{}",
                .{
                    resource.getClient().getCredentials().pid,
                    surface_id.index,
                    surface_id.generation,
                    root.index,
                    root.generation,
                    rectangle.x,
                    rectangle.y,
                    rectangle.width,
                    rectangle.height,
                    global.x,
                    global.y,
                    global.width,
                    global.height,
                },
            );
        }
        self.damageGlobalRect(global, root, surface_id);
    }
}

fn sceneWindowChanged(context: *anyopaque, scene_id: Scene.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (transitionIndex(self, scene_id)) |index| {
        const transition = &self.window_transitions.items[index];
        if (transition.phase == .animating and transition.kind != .disappearance) {
            transition.target_dirty = true;
        }
    }
    sceneNodeDamage(context, .{ .window = scene_id });
}

fn sceneVisibilityChanged(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.refreshIdleInhibition();
    if (self.image_copy_capture_initialized) self.image_copy_capture.refreshCursors();
    self.refreshKeyboardFocus();
}

fn sceneNodeDamage(context: *anyopaque, node: Scene.DamageNode) void {
    const self: *Self = @ptrCast(@alignCast(context));
    switch (node) {
        .window => |id| {
            // Transition rendering paints snapshots outside the window's
            // current bounds, so targeted damage cannot cover it.
            if (transitionIndex(self, id) != null) return requestRepaint(self);
            // The selected fullscreen window suppresses lower layers and
            // other nodes across the whole output, so any change to a
            // fullscreen window can alter pixels far outside its bounds.
            const window = self.sceneWindow(id) orelse return requestRepaint(self);
            if (window.fullscreen) return requestRepaint(self);
        },
        .shell_surface, .layer_surface, .popup => {},
    }
    // Unresolvable bounds usually mean the node's buffer was already dropped
    // by the commit that triggered this change; its previously rendered
    // pixels still need repair, so repaint everything.
    const bounds = self.sceneNodeBounds(node) orelse return requestRepaint(self);
    const root: ?Surface.Id = switch (node) {
        .window => |id| self.scene.windowSurface(id),
        .shell_surface => |id| if (self.scene.shellSurface(id)) |shell| shell.surface_id else null,
        .layer_surface => |id| if (self.scene.layerSurface(id)) |layer| layer.surface_id else null,
        .popup => |id| if (self.scene.popupFor(id)) |popup| popup.surface_id else null,
    };
    self.damageGlobalRect(bounds, root, null);
}

/// Conservative global bounds of everything a scene node currently paints:
/// surface trees, decorations, borders, shadows, and popups. Null means the
/// node renders nothing, so no damage is required for its current state.
fn sceneNodeBounds(self: *Self, node: Scene.DamageNode) ?render.Rect {
    return switch (node) {
        .window => |id| self.windowNodeBounds(id),
        .shell_surface => |id| self.shellSurfaceNodeBounds(id),
        .layer_surface => |id| self.layerSurfaceNodeBounds(id),
        .popup => |id| self.popupNodeBounds(id),
    };
}

fn windowNodeBounds(self: *Self, id: Scene.Id) ?render.Rect {
    const window = self.sceneWindow(id) orelse return null;
    var bounds: ?render.Rect = null;
    // Prefer the configured content geometry so bounds survive commits that
    // drop the buffer just before an unmap reaches the scene.
    const content_size: ?render.Size = if (window.content_geometry) |geometry|
        geometry.size
    else if (Surface.currentBuffer(self.compositor.surfaceStore(), window.surface_id)) |buffer|
        buffer.logical_size
    else
        null;
    const content_offset = if (window.content_geometry) |geometry|
        geometry.offset
    else
        Scene.Position{};
    if (content_size) |size| {
        if (window_geometry.windowContentRect(window, size)) |content_rect| {
            const caster = window_geometry.shadowCaster(
                content_rect,
                window.borders,
                window.effects.corner_radius,
            );
            var decorated = damage_geometry.effectsRect(caster.rect, window.effects);
            if (window.borders) |borders| {
                decorated = decorated.unionWith(
                    damage_geometry.expandRect(content_rect, borders.width),
                );
            }
            bounds = decorated;
        }
    }
    if (self.subcompositor.treeBounds(window.surface_id)) |tree| {
        const rect = treeBoundsRect(tree).translated(
            window.position.x -| content_offset.x,
            window.position.y -| content_offset.y,
        );
        bounds = if (bounds) |current| current.unionWith(rect) else rect;
    }
    inline for (.{ Scene.DecorationLayer.below, Scene.DecorationLayer.above }) |layer| {
        var decorations = self.scene.decorationIterator(id, layer);
        while (decorations.next()) |entry| {
            if (!entry.decoration.mapped) continue;
            const tree = self.subcompositor.treeBounds(entry.decoration.surface_id) orelse continue;
            const rect = treeBoundsRect(tree).translated(
                window.position.x +| entry.decoration.offset.x,
                window.position.y +| entry.decoration.offset.y,
            );
            bounds = if (bounds) |current| current.unionWith(rect) else rect;
        }
    }
    var popups = self.scene.popupIterator(id);
    while (popups.next()) |entry| {
        const rect = self.popupTreeBounds(entry.popup, entry.position) orelse continue;
        bounds = if (bounds) |current| current.unionWith(rect) else rect;
    }
    return bounds;
}

fn shellSurfaceNodeBounds(self: *Self, id: Scene.ShellSurfaceId) ?render.Rect {
    const shell_surface = self.scene.shellSurface(id) orelse return null;
    const tree = self.subcompositor.treeBounds(shell_surface.surface_id) orelse return null;
    return treeBoundsRect(tree).translated(
        shell_surface.position.x,
        shell_surface.position.y,
    );
}

fn layerSurfaceNodeBounds(self: *Self, id: Scene.LayerSurfaceId) ?render.Rect {
    const layer_surface = self.scene.layerSurface(id) orelse return null;
    // Unlike windows, layer surfaces retain no geometry once their buffer is
    // gone, so an unresolvable tree must escalate to a full repaint.
    const tree = self.subcompositor.treeBounds(layer_surface.surface_id) orelse return null;
    var bounds: ?render.Rect = treeBoundsRect(tree).translated(
        layer_surface.position.x,
        layer_surface.position.y,
    );
    var popups = self.scene.layerPopupIterator(id);
    while (popups.next()) |entry| {
        const rect = self.popupTreeBounds(entry.popup, entry.position) orelse continue;
        bounds = if (bounds) |current| current.unionWith(rect) else rect;
    }
    return bounds;
}

fn popupNodeBounds(self: *Self, id: Scene.PopupId) ?render.Rect {
    const popup = self.scene.popupFor(id) orelse return null;
    const position = self.scene.popupPosition(id) orelse return null;
    return self.popupTreeBounds(popup, position);
}

fn popupTreeBounds(
    self: *Self,
    popup: *const Scene.Popup,
    position: Scene.Position,
) ?render.Rect {
    if (!popup.mapped) return null;
    const offset = if (popup.content_geometry) |geometry|
        geometry.offset
    else
        Scene.Position{};
    const tree = self.subcompositor.treeBounds(popup.surface_id) orelse return null;
    return treeBoundsRect(tree).translated(
        position.x -| offset.x,
        position.y -| offset.y,
    );
}

fn treeBoundsRect(bounds: Subcompositor.TreeBounds) render.Rect {
    return .{
        .x = bounds.x,
        .y = bounds.y,
        .width = bounds.width,
        .height = bounds.height,
    };
}

fn transitionIndex(self: *Self, scene_id: Scene.Id) ?usize {
    for (self.window_transitions.items, 0..) |entry, index| {
        if (std.meta.eql(entry.scene_id, scene_id)) return index;
    }
    return null;
}

fn markWindowTransitionTargetDirty(self: *Self, root_id: Surface.Id) void {
    for (self.window_transitions.items) |*transition| {
        if (transition.phase != .animating or transition.kind == .disappearance) continue;
        if (std.meta.eql(transition.root_id, root_id)) {
            transition.target_dirty = true;
            requestRepaint(self);
            return;
        }
        var below = self.scene.decorationIterator(transition.scene_id, .below);
        while (below.next()) |entry| {
            if (std.meta.eql(entry.decoration.surface_id, root_id)) {
                transition.target_dirty = true;
                requestRepaint(self);
                return;
            }
        }
        var above = self.scene.decorationIterator(transition.scene_id, .above);
        while (above.next()) |entry| {
            if (std.meta.eql(entry.decoration.surface_id, root_id)) {
                transition.target_dirty = true;
                requestRepaint(self);
                return;
            }
        }
    }
}

fn destroyWindowTransition(self: *Self, index: usize) void {
    var entry = self.window_transitions.orderedRemove(index);
    const offscreen = self.renderer.offscreenAccess();
    entry.old.deinit(self.allocator, offscreen);
    if (entry.target) |*target| target.deinit(self.allocator, offscreen);
}

fn finishAllWindowTransitions(self: *Self) void {
    while (self.window_transitions.items.len != 0) {
        destroyWindowTransition(self, self.window_transitions.items.len - 1);
    }
}

fn finishWindowTransitionsForOutput(self: *Self, output_id: OutputLayout.Id) void {
    var index = self.window_transitions.items.len;
    while (index != 0) {
        index -= 1;
        if (std.meta.eql(self.window_transitions.items[index].output_id, output_id)) {
            destroyWindowTransition(self, index);
        }
    }
}

fn workspaceTransitionIndex(self: *const Self, output_id: OutputLayout.Id) ?usize {
    for (self.workspace_transitions.items, 0..) |transition, index| {
        if (std.meta.eql(transition.output_id, output_id)) return index;
    }
    return null;
}

fn destroyWorkspaceTransition(self: *Self, index: usize) void {
    var transition = self.workspace_transitions.orderedRemove(index);
    const offscreen = self.renderer.offscreenAccess();
    transition.old.deinit(self.allocator, offscreen);
    transition.transparent.deinit(self.allocator, offscreen);
}

fn finishAllWorkspaceTransitions(self: *Self) void {
    while (self.workspace_transitions.items.len != 0) {
        destroyWorkspaceTransition(self, self.workspace_transitions.items.len - 1);
    }
}

fn finishWorkspaceTransitionsForOutput(self: *Self, output_id: OutputLayout.Id) void {
    if (workspaceTransitionIndex(self, output_id)) |index| {
        destroyWorkspaceTransition(self, index);
    }
}

fn sceneWindow(self: *Self, id: Scene.Id) ?*const Scene.Window {
    var nodes = self.scene.nodeIterator();
    while (nodes.next()) |node| switch (node) {
        .window => |entry| if (std.meta.eql(entry.id, id)) return entry.window,
        else => {},
    };
    return null;
}

fn animationRect(rect: @TypeOf(@as(WindowManager.GeometryTransition, undefined).old_rect)) WindowAnimation.Rect {
    return .{ .x = rect.x, .y = rect.y, .width = rect.size.width, .height = rect.size.height };
}

fn renderAnimationRect(rect: WindowAnimation.Rect) render.Rect {
    return .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
}

fn currentWindowTransitionRect(transition: *const WindowTransition, now: i96) WindowAnimation.Rect {
    const factor = if (transition.phase == .waiting)
        0
    else
        WindowAnimation.progress(
            transition.start,
            now,
            transition.duration,
            transition.easing,
        );
    return WindowAnimation.constrainSplitOuterEdge(
        WindowAnimation.interpolate(transition.old_rect, transition.target_rect, factor),
        transition.old_rect,
        transition.target_rect,
    );
}

fn allocateWindowSnapshot(self: *Self, physical_size: render.Size) !WindowAnimation.Snapshot {
    if (self.renderer.offscreenAccess()) |access| {
        const target = try access.create_target(access.context, physical_size);
        return .{ .source = .{ .offscreen = target } };
    }
    const pixels = try self.allocator.alloc(u32, try physical_size.pixelCount());
    return .{
        .source = .{ .pixels = .{
            .size = physical_size,
            .stride_pixels = physical_size.width,
            .pixels = pixels,
        } },
        .owned_pixels = pixels,
    };
}

fn captureTransparentSnapshot(
    self: *Self,
    output_id: OutputLayout.Id,
    rect: WindowAnimation.Rect,
) !WindowAnimation.Snapshot {
    const render_output = self.findProtocolRenderOutput(output_id) orelse return error.InvalidTarget;
    const scale = render_output.backend.renderScale();
    const physical_size = try scale.apply(.{ .width = rect.width, .height = rect.height });
    if (physical_size.width == 0 or physical_size.height == 0) return error.InvalidTarget;
    var snapshot = try self.allocateWindowSnapshot(physical_size);
    errdefer snapshot.deinit(self.allocator, self.renderer.offscreenAccess());
    try self.renderer.beginFrame(
        switch (snapshot.source) {
            .pixels => |pixels| .{ .pixels = pixels },
            .offscreen => |target| .{ .offscreen = target },
        },
        scale,
        .{ .x = rect.x, .y = rect.y },
        null,
        render_output.color_description,
    );
    var active = true;
    errdefer if (active) self.renderer.cancelFrame();
    try self.renderer.append(&.{.{ .clear = render.Color.rgba(0, 0, 0, 0) }});
    active = false;
    try self.renderer.finishFrame();
    return snapshot;
}

fn captureWindowSnapshot(
    self: *Self,
    scene_id: Scene.Id,
    output_id: OutputLayout.Id,
    rect: WindowAnimation.Rect,
) !WindowAnimation.Snapshot {
    const window = self.sceneWindow(scene_id) orelse return error.InvalidTarget;
    const render_output = self.findProtocolRenderOutput(output_id) orelse return error.InvalidTarget;
    const scale = render_output.backend.renderScale();
    const logical_size: render.Size = .{ .width = rect.width, .height = rect.height };
    const physical_size = try scale.apply(logical_size);
    if (physical_size.width == 0 or physical_size.height == 0) return error.InvalidTarget;

    var snapshot = try self.allocateWindowSnapshot(physical_size);
    errdefer snapshot.deinit(self.allocator, self.renderer.offscreenAccess());
    self.renderer.beginFrame(
        switch (snapshot.source) {
            .pixels => |p| .{ .pixels = p },
            .offscreen => |t| .{ .offscreen = t },
        },
        scale,
        .{ .x = rect.x, .y = rect.y },
        null,
        render_output.color_description,
    ) catch |err| return err;
    var active = true;
    errdefer if (active) self.renderer.cancelFrame();
    var capture_id: u32 = 1;
    const output = self.outputs.get(output_id) orelse return error.InvalidTarget;
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .visible_rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height },
        .track_visibility = false,
        .next_backdrop_capture_id = &capture_id,
    };
    try self.renderCommands(&frame, &.{.{ .clear = render.Color.rgba(0, 0, 0, 0) }});
    const geometry = window.content_geometry orelse Scene.ContentGeometry{ .size = logical_size };
    const tree_x = window.position.x -| geometry.offset.x;
    const tree_y = window.position.y -| geometry.offset.y;
    const backdrop_capture_id = try self.renderSurfaceTreeCapture(
        &frame,
        window.surface_id,
        tree_x,
        tree_y,
        null,
        null,
    );
    try self.renderWindowDecorations(&frame, scene_id, window, .below, null);
    try self.renderSurfaceTreeContents(
        &frame,
        window.surface_id,
        tree_x,
        tree_y,
        null,
        null,
        backdrop_capture_id,
    );
    try self.renderWindowDecorations(&frame, scene_id, window, .above, null);
    active = false;
    try self.renderer.finishFrame();
    return snapshot;
}

fn captureWindowTransitionSnapshot(
    self: *Self,
    transition: *const WindowTransition,
    now: i96,
    rect: WindowAnimation.Rect,
) !WindowAnimation.Snapshot {
    const render_output = self.findProtocolRenderOutput(transition.output_id) orelse
        return error.InvalidTarget;
    const output = self.outputs.get(transition.output_id) orelse return error.InvalidTarget;
    const scale = render_output.backend.renderScale();
    const physical_size = try scale.apply(.{ .width = rect.width, .height = rect.height });
    if (physical_size.width == 0 or physical_size.height == 0) return error.InvalidTarget;
    var snapshot = try self.allocateWindowSnapshot(physical_size);
    errdefer snapshot.deinit(self.allocator, self.renderer.offscreenAccess());
    try self.renderer.beginFrame(
        switch (snapshot.source) {
            .pixels => |pixels| .{ .pixels = pixels },
            .offscreen => |target| .{ .offscreen = target },
        },
        scale,
        .{ .x = rect.x, .y = rect.y },
        null,
        render_output.color_description,
    );
    var active = true;
    errdefer if (active) self.renderer.cancelFrame();
    var capture_id: u32 = 1;
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .visible_rect = renderAnimationRect(rect),
        .track_visibility = false,
        .next_backdrop_capture_id = &capture_id,
    };
    try self.renderCommands(&frame, &.{.{ .clear = render.Color.rgba(0, 0, 0, 0) }});
    const previous_animation_now = self.animation_now;
    self.animation_now = now;
    defer self.animation_now = previous_animation_now;
    try self.renderWindowTransition(&frame, transition, .{}, null, false);
    active = false;
    try self.renderer.finishFrame();
    return snapshot;
}

fn captureDesktopSnapshot(
    self: *Self,
    output_id: OutputLayout.Id,
) !WindowAnimation.Snapshot {
    const render_output = self.findProtocolRenderOutput(output_id) orelse return error.InvalidTarget;
    const output = self.outputs.get(output_id) orelse return error.InvalidTarget;
    const rect = output.logicalRect();
    const scale = render_output.backend.renderScale();
    var snapshot = try self.allocateWindowSnapshot(render_output.backend.modeSize());
    errdefer snapshot.deinit(self.allocator, self.renderer.offscreenAccess());
    try self.renderer.beginFrame(
        switch (snapshot.source) {
            .pixels => |pixels| .{ .pixels = pixels },
            .offscreen => |target| .{ .offscreen = target },
        },
        scale,
        .{ .x = rect.x, .y = rect.y },
        null,
        render_output.color_description,
    );
    var active = true;
    errdefer if (active) self.renderer.cancelFrame();
    var capture_id: u32 = 1;
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .visible_rect = rect,
        .track_visibility = false,
        .next_backdrop_capture_id = &capture_id,
    };
    try self.renderCommands(&frame, &.{.{
        .clear = outputClearColor(self.palette, false),
    }});
    const previous_animation_now = self.animation_now;
    self.animation_now = nowNanoseconds(self.io);
    defer self.animation_now = previous_animation_now;
    _ = try self.renderDesktopContents(&frame, false, false);
    active = false;
    try self.renderer.finishFrame();
    return snapshot;
}

fn workspaceTransitionPrepare(context: *anyopaque, output_id: OutputLayout.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.reduced_motion or self.session_lock.isLocked() or
        self.window_manager.directManipulationActive() or self.hasMappedClientPopup())
    {
        finishWorkspaceTransitionsForOutput(self, output_id);
        return;
    }
    const output = self.outputs.get(output_id) orelse return;
    const logical = output.logicalRect();
    const rect: WindowAnimation.Rect = .{
        .x = logical.x,
        .y = logical.y,
        .width = logical.width,
        .height = logical.height,
    };
    var old = self.captureDesktopSnapshot(output_id) catch |err| {
        log.warn("failed to capture old workspace: {t}", .{err});
        finishWorkspaceTransitionsForOutput(self, output_id);
        return;
    };
    finishWorkspaceTransitionsForOutput(self, output_id);
    finishWindowTransitionsForOutput(self, output_id);
    var transparent = self.captureTransparentSnapshot(output_id, rect) catch |err| {
        log.warn("failed to create transparent workspace snapshot: {t}", .{err});
        old.deinit(self.allocator, self.renderer.offscreenAccess());
        return;
    };
    self.workspace_transitions.append(self.allocator, .{
        .output_id = output_id,
        .rect = rect,
        .old = old,
        .transparent = transparent,
    }) catch {
        old.deinit(self.allocator, self.renderer.offscreenAccess());
        transparent.deinit(self.allocator, self.renderer.offscreenAccess());
        return;
    };
}

fn workspaceTransitionPublished(context: *anyopaque, output_id: OutputLayout.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const index = workspaceTransitionIndex(self, output_id) orelse return;
    const transition = &self.workspace_transitions.items[index];
    transition.phase = .animating;
    transition.start = nowNanoseconds(self.io);
    requestRepaint(self);
}

fn geometryTransitionPrepare(context: *anyopaque, transition: WindowManager.GeometryTransition) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.reduced_motion or self.xdg_shell.hasPopupGrab()) return;
    if (self.window_transitions.items.len == maximum_window_transitions and
        transitionIndex(self, transition.scene_id) == null) return;
    const current_buffer = Surface.currentBuffer(
        self.compositor.surfaceStore(),
        transition.surface_id,
    ) orelse return;
    var old_rect = animationRect(transition.old_rect);
    var materialized: ?WindowAnimation.Snapshot = null;
    if (transitionIndex(self, transition.scene_id)) |index| {
        const active = &self.window_transitions.items[index];
        if (active.phase != .waiting) {
            const now = nowNanoseconds(self.io);
            const displayed_rect = currentWindowTransitionRect(active, now);
            materialized = self.captureWindowTransitionSnapshot(
                active,
                now,
                displayed_rect,
            ) catch |err| capture: {
                log.warn("failed to materialize interrupted window transition: {t}", .{err});
                break :capture null;
            };
            if (materialized == null) {
                destroyWindowTransition(self, index);
                requestRepaint(self);
                return;
            }
            old_rect = displayed_rect;
        }
        destroyWindowTransition(self, index);
    }
    const snapshot = materialized orelse self.captureWindowSnapshot(
        transition.scene_id,
        transition.output,
        old_rect,
    ) catch |err| {
        log.warn("failed to capture old tiling snapshot: {t}", .{err});
        return;
    };
    const target_rect = animationRect(transition.target_rect);
    var duration = WindowAnimation.reflowDuration(old_rect, target_rect);
    for (self.window_transitions.items) |*existing| {
        if (existing.kind != .reflow or existing.phase != .waiting or
            !std.meta.eql(existing.output_id, transition.output)) continue;
        duration = @max(duration, existing.duration);
    }
    for (self.window_transitions.items) |*existing| {
        if (existing.kind == .reflow and existing.phase == .waiting and
            std.meta.eql(existing.output_id, transition.output)) existing.duration = duration;
    }
    self.window_transitions.append(self.allocator, .{
        .kind = .reflow,
        .scene_id = transition.scene_id,
        .root_id = transition.surface_id,
        .output_id = transition.output,
        .old_rect = old_rect,
        .target_rect = target_rect,
        .old_source_cache = current_buffer.source_cache,
        .buffer_update_required = transition.old_rect.size.width != transition.target_rect.size.width or
            transition.old_rect.size.height != transition.target_rect.size.height,
        .old = snapshot,
        .duration = duration,
        .easing = .existing,
    }) catch {
        var owned = snapshot;
        owned.deinit(self.allocator, self.renderer.offscreenAccess());
        return;
    };
    refreshWindowDisappearanceTargets(self, transition.output);
    requestRepaint(self);
}

fn transitionTargetReady(self: *Self, entry: *const WindowTransition) bool {
    if (entry.kind == .appearance) return true;
    const buffer = Surface.currentBuffer(self.compositor.surfaceStore(), entry.root_id) orelse
        return false;
    return WindowAnimation.targetReady(
        entry.buffer_update_required,
        entry.old_source_cache,
        buffer.source_cache,
    );
}

const StartWindowTransitionResult = enum { not_ready, started, removed };

fn startWindowTransition(self: *Self, index: usize) StartWindowTransitionResult {
    const entry = &self.window_transitions.items[index];
    if (!transitionTargetReady(self, entry)) return .not_ready;
    const target = self.captureWindowSnapshot(
        entry.scene_id,
        entry.output_id,
        entry.target_rect,
    ) catch |err| {
        log.warn("failed to capture target tiling snapshot: {t}", .{err});
        destroyWindowTransition(self, index);
        return .removed;
    };
    entry.target = target;
    entry.target_dirty = false;
    entry.phase = .animating;
    return .started;
}

fn geometryTransitionPublished(context: *anyopaque, scene_id: Scene.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const index = transitionIndex(self, scene_id) orelse return;
    const entry = &self.window_transitions.items[index];
    entry.start = nowNanoseconds(self.io);
    entry.phase = .target_pending;
    requestRepaint(self);
}

fn refreshWindowTransitionTarget(self: *Self, index: usize) bool {
    const entry = &self.window_transitions.items[index];
    const target = self.captureWindowSnapshot(
        entry.scene_id,
        entry.output_id,
        entry.target_rect,
    ) catch |err| {
        log.warn("failed to refresh tiling animation target: {t}", .{err});
        destroyWindowTransition(self, index);
        return false;
    };
    var previous = entry.target;
    entry.target = target;
    entry.target_dirty = false;
    if (previous) |*snapshot| snapshot.deinit(self.allocator, self.renderer.offscreenAccess());
    return true;
}

const WindowReflowMatch = enum { vacated, absorbed };

const WindowMotion = struct {
    rect: WindowAnimation.Rect,
    duration: u64,
    easing: WindowAnimation.Easing,
    opacity_transition: bool,
};

fn windowReflowIndex(
    self: *const Self,
    output_id: OutputLayout.Id,
    rect: WindowAnimation.Rect,
    match: WindowReflowMatch,
) ?usize {
    var result: ?usize = null;
    var largest_area: u64 = 0;
    for (self.window_transitions.items, 0..) |transition, index| {
        if (transition.kind != .reflow or !std.meta.eql(transition.output_id, output_id)) continue;
        const old_overlap = WindowAnimation.overlapArea(transition.old_rect, rect);
        const target_overlap = WindowAnimation.overlapArea(transition.target_rect, rect);
        const area = switch (match) {
            .vacated => old_overlap -| target_overlap,
            .absorbed => target_overlap -| old_overlap,
        };
        if (area <= largest_area) continue;
        largest_area = area;
        result = index;
    }
    return result;
}

fn windowAppearanceMotion(
    self: *const Self,
    output_id: OutputLayout.Id,
    target_rect: WindowAnimation.Rect,
    coordinated: bool,
) WindowMotion {
    if (coordinated) if (self.windowReflowIndex(output_id, target_rect, .vacated)) |index| {
        const reflow = self.window_transitions.items[index];
        return .{
            .rect = WindowAnimation.splitCollapsedRect(reflow.target_rect, target_rect),
            .duration = reflow.duration,
            .easing = reflow.easing,
            .opacity_transition = false,
        };
    };
    return .{
        .rect = WindowAnimation.appearanceStart(target_rect),
        .duration = WindowAnimation.fast_duration_nanoseconds,
        .easing = .entrance,
        .opacity_transition = true,
    };
}

fn windowDisappearanceMotion(
    self: *const Self,
    output_id: OutputLayout.Id,
    closing_rect: WindowAnimation.Rect,
    coordinated: bool,
) WindowMotion {
    if (coordinated) if (self.windowReflowIndex(output_id, closing_rect, .absorbed)) |index| {
        const reflow = self.window_transitions.items[index];
        return .{
            .rect = WindowAnimation.splitCollapsedRect(reflow.old_rect, closing_rect),
            .duration = reflow.duration,
            .easing = reflow.easing,
            .opacity_transition = false,
        };
    };
    return .{
        .rect = WindowAnimation.appearanceStart(closing_rect),
        .duration = WindowAnimation.fast_duration_nanoseconds,
        .easing = .exit,
        .opacity_transition = true,
    };
}

fn refreshWindowDisappearanceTargets(self: *Self, output_id: OutputLayout.Id) void {
    for (0..self.window_transitions.items.len) |index| {
        const transition = self.window_transitions.items[index];
        if (transition.kind != .disappearance or
            transition.phase != .waiting or
            !std.meta.eql(transition.output_id, output_id)) continue;
        const motion = self.windowDisappearanceMotion(
            output_id,
            transition.old_rect,
            transition.coordinated,
        );
        self.window_transitions.items[index].target_rect = motion.rect;
        self.window_transitions.items[index].duration = motion.duration;
        self.window_transitions.items[index].easing = motion.easing;
        self.window_transitions.items[index].opacity_transition = motion.opacity_transition;
    }
}

fn geometryTransitionAppeared(
    context: *anyopaque,
    appearance: WindowManager.GeometryAppearance,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.reduced_motion or self.session_lock.isLocked() or self.xdg_shell.hasPopupGrab()) return;
    if (transitionIndex(self, appearance.scene_id)) |index| destroyWindowTransition(self, index);
    if (self.window_transitions.items.len == maximum_window_transitions) return;
    const target_rect = animationRect(appearance.target_rect);
    const motion = self.windowAppearanceMotion(
        appearance.output,
        target_rect,
        appearance.coordinated,
    );
    var old = self.captureTransparentSnapshot(appearance.output, target_rect) catch |err| {
        log.warn("failed to create empty window appearance snapshot: {t}", .{err});
        return;
    };
    const buffer = Surface.currentBuffer(
        self.compositor.surfaceStore(),
        appearance.surface_id,
    ) orelse {
        old.deinit(self.allocator, self.renderer.offscreenAccess());
        return;
    };
    self.window_transitions.append(self.allocator, .{
        .kind = .appearance,
        .scene_id = appearance.scene_id,
        .root_id = appearance.surface_id,
        .output_id = appearance.output,
        .old_rect = motion.rect,
        .target_rect = target_rect,
        .old_source_cache = buffer.source_cache,
        .buffer_update_required = false,
        .old = old,
        .coordinated = appearance.coordinated,
        .opacity_transition = motion.opacity_transition,
        .phase = .target_pending,
        .start = nowNanoseconds(self.io),
        .duration = motion.duration,
        .easing = motion.easing,
    }) catch {
        old.deinit(self.allocator, self.renderer.offscreenAccess());
        return;
    };
    requestRepaint(self);
}

fn geometryTransitionClosing(
    context: *anyopaque,
    closure: WindowManager.GeometryAppearance,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.reduced_motion or self.session_lock.isLocked() or self.xdg_shell.hasPopupGrab()) return;
    if (windowTransitionHasPopup(self, closure.scene_id)) return;
    const window = self.sceneWindow(closure.scene_id) orelse return;
    if (transitionIndex(self, closure.scene_id)) |index| destroyWindowTransition(self, index);
    if (self.window_transitions.items.len == maximum_window_transitions) return;
    const rect = animationRect(closure.target_rect);
    var old = self.captureWindowSnapshot(closure.scene_id, closure.output, rect) catch |err| {
        log.warn("failed to capture closing window: {t}", .{err});
        return;
    };
    const buffer = Surface.currentBuffer(
        self.compositor.surfaceStore(),
        closure.surface_id,
    ) orelse {
        old.deinit(self.allocator, self.renderer.offscreenAccess());
        return;
    };
    var transparent = self.captureTransparentSnapshot(closure.output, rect) catch |err| {
        log.warn("failed to create empty closing window snapshot: {t}", .{err});
        old.deinit(self.allocator, self.renderer.offscreenAccess());
        return;
    };
    const motion = self.windowDisappearanceMotion(
        closure.output,
        rect,
        closure.coordinated,
    );
    self.window_transitions.append(self.allocator, .{
        .kind = .disappearance,
        .scene_id = closure.scene_id,
        .root_id = closure.surface_id,
        .output_id = closure.output,
        .old_rect = rect,
        .target_rect = motion.rect,
        .old_source_cache = buffer.source_cache,
        .buffer_update_required = false,
        .old = old,
        .target = transparent,
        .coordinated = closure.coordinated,
        .opacity_transition = motion.opacity_transition,
        .detached = true,
        .effects = window.effects,
        .borders = window.borders,
        .duration = motion.duration,
        .easing = motion.easing,
    }) catch {
        old.deinit(self.allocator, self.renderer.offscreenAccess());
        transparent.deinit(self.allocator, self.renderer.offscreenAccess());
        return;
    };
    requestRepaint(self);
}

fn windowTransitionHasPopup(self: *Self, scene_id: Scene.Id) bool {
    if (transitionIndex(self, scene_id)) |index| {
        if (self.window_transitions.items[index].detached) return false;
    }
    var popups = self.scene.popupIterator(scene_id);
    while (popups.next()) |entry| if (entry.popup.mapped) return true;
    return false;
}

fn hasMappedClientPopup(self: *Self) bool {
    var nodes = self.scene.nodeIterator();
    while (nodes.next()) |node| switch (node) {
        .window => |entry| {
            if (!entry.window.mapped) continue;
            var popups = self.scene.popupIterator(entry.id);
            while (popups.next()) |popup| if (popup.popup.mapped) return true;
        },
        .shell_surface => {},
    };
    inline for (.{
        Scene.Layer.background,
        Scene.Layer.bottom,
        Scene.Layer.top,
        Scene.Layer.overlay,
    }) |layer| {
        var roots = self.scene.layerSurfaceIterator(layer);
        while (roots.next()) |root| {
            if (!root.layer_surface.mapped) continue;
            var popups = self.scene.layerPopupIterator(root.id);
            while (popups.next()) |popup| if (popup.popup.mapped) return true;
        }
    }
    return false;
}

fn geometryTransitionRemoved(context: *anyopaque, scene_id: Scene.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (transitionIndex(self, scene_id)) |index| {
        if (self.window_transitions.items[index].kind == .disappearance) {
            self.window_transitions.items[index].detached = true;
        } else {
            destroyWindowTransition(self, index);
        }
    }
}

fn markSurfaceTreeVisible(self: *Self, output: *Output, surface_id: Surface.Id) !void {
    if (Surface.currentBuffer(self.compositor.surfaceStore(), surface_id) == null) return;
    var stack = self.subcompositor.stackIterator(surface_id);
    while (stack.next()) |entry| switch (entry) {
        .parent => {
            try output.markSurfaceVisible(surface_id);
            Surface.markFifoBarrierVisible(self.compositor.surfaceStore(), surface_id, output);
        },
        .child => |child| try self.markSurfaceTreeVisible(output, child.surface_id),
    };
}

fn scheduleSurfaceFrameCallback(self: *Self, surface_id: Surface.Id) void {
    const surfaces = self.compositor.surfaceStore();
    if (!Surface.hasCallbackOnlyFrameCallback(surfaces, surface_id)) return;

    var render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| {
        const render_output = entry.value.*;
        if (!render_output.backend.powered()) continue;
        const output = self.outputs.get(render_output.protocol_id).?;
        if (!output.containsSurface(surface_id)) continue;
        self.scheduleFrameCallback(render_output);
    }
}

fn cursorBounds(self: *Self, cursor: Seat.CursorInfo) ?render.Rect {
    return switch (cursor) {
        .shape => |shape| .{
            .x = shape.x,
            .y = shape.y,
            .width = shape.buffer.size.width,
            .height = shape.buffer.size.height,
        },
        .surface => |surface| bounds: {
            var value: ?render.Rect = null;
            self.addSurfaceTreeBounds(
                surface.surface_id,
                surface.x,
                surface.y,
                &value,
            ) catch return null;
            break :bounds value;
        },
    };
}

fn damageGlobalRect(
    self: *Self,
    rectangle: render.Rect,
    source_root: ?Surface.Id,
    committed_surface: ?Surface.Id,
) void {
    // Surface commits carry their root for source-aware capture invalidation.
    // Their exact surface also restricts damage to outputs where its image
    // survived occlusion pruning in the previous frame. Scene-node changes
    // remain unfiltered so mapping, movement, and exposure still repaint.
    // Cursors are painted after backdrop captures and only damage their bounds.
    var render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| {
        const render_output = entry.value.*;
        if (!render_output.backend.powered()) continue;
        const output = self.outputs.get(render_output.protocol_id).?;
        if (committed_surface) |surface_id| {
            if (render_output.sampled_surfaces_valid and
                !surfaceWasSampled(render_output, surface_id)) continue;
        }
        const output_rect = output.logicalRect();
        const intersection = rectangle.intersection(output_rect) orelse continue;
        const physical = damage_geometry.scaleRect(
            .{
                .x = intersection.x -| output_rect.x,
                .y = intersection.y -| output_rect.y,
                .width = intersection.width,
                .height = intersection.height,
            },
            render_output.backend.renderScale(),
            render_output.backend.modeSize(),
        ) orelse continue;
        if (source_root) |root| {
            var surface_damage = Region.init();
            defer surface_damage.deinit();
            surface_damage.setRectangle(
                physical.x,
                physical.y,
                physical.width,
                physical.height,
            );
            self.expandBackdropBlurDamage(
                render_output,
                output,
                &surface_damage,
                root,
            ) catch {
                self.damageFullOutput(render_output);
                continue;
            };
            if (Logging.enabled(.debug) and surface_damage.coversRectangle(
                0,
                0,
                render_output.backend.modeSize().width,
                render_output.backend.modeSize().height,
            )) {
                log.debug(
                    "surface damage expanded to full output: root={}:{} source={},{},{}x{}",
                    .{
                        root.index,
                        root.generation,
                        physical.x,
                        physical.y,
                        physical.width,
                        physical.height,
                    },
                );
            }
            var rectangles = surface_damage.rectangleIterator();
            while (rectangles.next()) |damaged| {
                render_output.damage.add(
                    damaged.x,
                    damaged.y,
                    @intCast(damaged.width),
                    @intCast(damaged.height),
                ) catch {
                    self.damageFullOutput(render_output);
                    break;
                };
            }
        } else {
            render_output.damage.add(
                physical.x,
                physical.y,
                @intCast(physical.width),
                @intCast(physical.height),
            ) catch {
                self.damageFullOutput(render_output);
                continue;
            };
        }
        render_output.requestFrame();
        self.scheduleRepaint(render_output);
    }
}

noinline fn damageFullOutput(self: *Self, output: *RenderOutput) void {
    log.debug("full output damage requested by 0x{x}", .{@returnAddress()});
    const size = output.backend.modeSize();
    output.damage.setRectangle(0, 0, size.width, size.height);
    output.requestFrame();
    self.scheduleRepaint(output);
}

fn preservePromotedDamage(damage: *Region, destination: render.Rect, output_size: render.Size) void {
    // The primary omits this image, so it remains stale until a later frame
    // repaints the rect beneath either a replacement overlay or normal composition.
    damage.add(
        destination.x,
        destination.y,
        @intCast(destination.width),
        @intCast(destination.height),
    ) catch damage.setRectangle(0, 0, output_size.width, output_size.height);
}

fn surfaceWasSampled(output: *const RenderOutput, surface_id: Surface.Id) bool {
    for (output.sampled_surfaces.items) |candidate| {
        if (std.meta.eql(candidate, surface_id)) return true;
    }
    return false;
}

fn rememberSampledSurfaces(self: *Self, output: *RenderOutput) void {
    const surfaces = self.compositor.surfaceStore();
    output.sampled_surfaces.ensureTotalCapacity(self.allocator, surfaces.len()) catch {
        // Allocation failure disables this optimization rather than risking
        // missed damage from an incomplete contribution set.
        output.sampled_surfaces.clearRetainingCapacity();
        output.sampled_surfaces_valid = false;
        return;
    };
    output.sampled_surfaces.clearRetainingCapacity();
    var iterator = surfaces.iterator();
    while (iterator.next()) |entry| {
        if (self.renderer.wasSampled(surfaceSampleTag(entry.id))) {
            output.sampled_surfaces.appendAssumeCapacity(entry.id);
        }
    }
    output.sampled_surfaces_valid = true;
}

fn outputDamageRectangles(
    self: *Self,
    output: *RenderOutput,
    damage: *const Region,
) error{OutOfMemory}![]const render.Rect {
    output.damage_rectangles.clearRetainingCapacity();
    var rectangles = damage.rectangleIterator();
    while (rectangles.next()) |rectangle| {
        try output.damage_rectangles.append(self.allocator, .{
            .x = rectangle.x,
            .y = rectangle.y,
            .width = rectangle.width,
            .height = rectangle.height,
        });
    }
    return output.damage_rectangles.items;
}

fn clearCursorShapes(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.seat.clearCursorShapes();
    self.tablet.clearCursorShapes();
}

fn idleInhibitorsChanged(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.refreshIdleInhibition();
}

fn idleNotifyFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.terminate();
}

fn refreshIdleInhibition(self: *Self) void {
    if (!self.idle_notify_initialized) return;
    self.idle_notify.setInhibited(self.idle_inhibit.hasVisibleInhibitor(
        self,
        idleInhibitorSurfaceVisible,
    ));
}

fn idleInhibitorSurfaceVisible(context: *anyopaque, surface_id: Surface.Id) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    const root = self.subcompositor.rootSurface(surface_id);
    if (self.session_lock.isLocked()) return self.session_lock.ownsSurface(root);
    return self.scene.surfaceMapped(root);
}

fn workspaceActivationRequested(context: *anyopaque, output: OutputLayout.Id, number: u8) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.window_manager_initialized) return false;
    return self.window_manager.activateWorkspaceFromProtocol(output, number);
}

fn xdgActivationRequested(
    context: *anyopaque,
    surface_id: Surface.Id,
    proven_interaction: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.window_manager_initialized) return;
    const allow_focus = proven_interaction and !self.session_lock.isLocked();
    if (self.window_manager.activationRequested(surface_id, allow_focus)) requestRepaint(self);
}

fn sessionLockStateChanged(context: *anyopaque, locked: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized) self.window_manager.setSessionLocked(locked);
    if (locked) {
        finishAllWindowTransitions(self);
        finishAllWorkspaceTransitions(self);
    }
    self.refreshIdleInhibition();
    self.reconcileOutputCursors();
    if (locked) self.xwayland_keyboard_grab.cancelAll();
    if (self.window_manager_initialized and self.endCompositorPointerGrab(false)) {
        requestRepaint(self);
    }
    self.seat.setCompositorCursor(null);
    self.pointer_constraints.deactivateAll();
    self.data_device.cancel();
    self.tablet.cancelFocus();
    self.cancelSeatTouches(&self.seat);
    self.seat.suppressPointerFocus(true);
    self.xdg_shell.dismissPopupGrab();
    if (locked) {
        self.virtual_keyboard.setInhibited(true);
        self.input_method.setInhibited(true);
        self.seat.setKeyboardFocus(null);
    } else {
        self.seat.setKeyboardFocus(null);
        self.input_method.setInhibited(false);
        self.virtual_keyboard.setInhibited(false);
        if (self.seat.pointerPosition()) |position| {
            const route = self.pointerRoute(position.x, position.y);
            self.seat.pointerEnter(position.x, position.y, route.focus);
            self.updateResizeCursor(route.root, position.x, position.y);
            self.pointer_constraints.syncFocus();
        }
    }
}

fn inputMethodSurfacePosition(context: *anyopaque, surface_id: Surface.Id) ?InputMethod.Position {
    const self: *Self = @ptrCast(@alignCast(context));
    const position = self.scene.surfacePosition(surface_id) orelse return null;
    return .{ .x = position.x, .y = position.y };
}

fn inputMethodOutputSize(context: *anyopaque) render.Size {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.primaryRenderOutput().backend.size();
}

fn primaryRenderOutput(self: *Self) *RenderOutput {
    return self.render_outputs.get(self.primary_render_output).?.*;
}

fn scheduleRepaint(self: *Self, output: *RenderOutput) void {
    if (!output.repaint_needed or output.render_scheduled or !output.backend.ready()) return;
    if (output.backend.repaintIntervalNanoseconds()) |interval| {
        const schedule = periodicTimerSchedule(
            nowNanoseconds(self.io),
            output.repaint_deadline_nanoseconds,
            interval,
        );
        output.repaint_deadline_nanoseconds = schedule.deadline_nanoseconds;
        output.repaint_target_vblank_nanoseconds = null;
        const timer = output.timer orelse unreachable;
        timer.timerUpdate(schedule.delay_milliseconds) catch |err| {
            log.err("failed to schedule repaint: {t}", .{err});
            self.terminate();
            return;
        };
    } else if (self.repaintDelay(output)) |delay| {
        // Deferring the render toward the predicted vblank shortens the
        // damage-to-presentation latency without missing the deadline.
        increment(&output.frame_statistics.repaints_delayed);
        output.repaint_target_vblank_nanoseconds = delay.target_vblank_nanoseconds;
        const timer = output.timer orelse unreachable;
        timer.timerUpdate(delay.delay_milliseconds) catch |err| {
            log.err("failed to schedule repaint: {t}", .{err});
            self.terminate();
            return;
        };
    } else {
        std.debug.assert(output.repaint_idle == null);
        increment(&output.frame_statistics.repaints_immediate);
        output.repaint_target_vblank_nanoseconds = null;
        output.repaint_idle = self.display.getEventLoop().addIdle(
            *RenderOutput,
            handleRenderIdle,
            output,
        ) catch |err| {
            log.err("failed to schedule repaint: {t}", .{err});
            self.terminate();
            return;
        };
    }
    output.render_scheduled = true;
}

const RepaintDelay = struct {
    delay_milliseconds: i32,
    target_vblank_nanoseconds: i96,
};

/// Delay for the pending repaint toward the next vblank together with the
/// vblank it targets, or null when the output must render immediately: the
/// backend cannot predict vblanks, the render-cost window is not full, or
/// the deadline is already too close.
fn repaintDelay(self: *Self, output: *RenderOutput) ?RepaintDelay {
    if (!output.backend.supportsRepaintDelay()) return null;
    const budget = output.render_budget.budgetNanoseconds() orelse return null;
    const now = nowNanoseconds(self.io);
    const next_vblank = output.backend.nextVblankNanoseconds(now) orelse return null;
    const delay = repaintDelayFromDeadline(now, next_vblank, budget) orelse return null;
    return .{
        .delay_milliseconds = delay,
        .target_vblank_nanoseconds = next_vblank,
    };
}

fn scheduleFrameCallback(self: *Self, output: *RenderOutput) void {
    if (!output.backend.powered()) return;
    const schedule = periodicTimerSchedule(
        nowNanoseconds(self.io),
        output.frame_callback_deadline_nanoseconds,
        outputRefreshNanoseconds(output.backend.refreshMillihertz()),
    );
    output.frame_callback_deadline_nanoseconds = schedule.deadline_nanoseconds;
    const timer = output.frame_callback_timer orelse unreachable;
    timer.timerUpdate(schedule.delay_milliseconds) catch |err| {
        log.err("failed to schedule frame callback: {t}", .{err});
        self.terminate();
        return;
    };
    output.frame_callback_scheduled = true;
}

fn outputReady(context: *anyopaque) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    output.server.scheduleRepaint(output);
}

fn outputPresented(context: *anyopaque, info: presentation.Info) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const transition_presented = output.cursor_transition_committed;
    output.presentFrame(info);
    if (transition_presented) {
        output.cursor_transition_committed = false;
        switch (output.cursor_state) {
            .activating => {
                const cursor = self.seatCursorInfo(&self.seat, self.session_lock.isLocked());
                if (self.shapeCursorForOutput(output, cursor)) |shape| {
                    output.cursor_state = if (output.backend.setShapeCursor(shape)) .hardware else .software;
                    if (output.cursor_state == .software) self.damageOutputCursor(output, cursor);
                } else {
                    output.cursor_state = .software;
                    self.damageOutputCursor(output, cursor);
                }
            },
            .deactivating => {
                if (output.backend.disableShapeCursor()) {
                    output.cursor_state = .software;
                    const cursor = self.seatCursorInfo(&self.seat, self.session_lock.isLocked());
                    self.updateOutputCursor(output, cursor, cursor);
                } else {
                    self.damageFullOutput(output);
                }
            },
            else => {},
        }
    }
    const protocol_output = self.outputs.get(output.protocol_id).?;
    protocol_output.setRefresh(info);
    Surface.finishPresentation(self.compositor.surfaceStore(), protocol_output, info);
    output.frame_callback_deadline_nanoseconds = nowNanoseconds(self.io);
    if (protocol_output.hasCallbackOnlyFrameCallbacks()) self.scheduleFrameCallback(output);
    if (output.lock_frame_pending) {
        output.lock_frame_pending = false;
        self.session_lock.outputPresented(output.protocol_id);
    }
}

fn outputDiscarded(context: *anyopaque) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    output.discardFrame();
    output.cursor_transition_committed = false;
    output.lock_frame_pending = false;
    Surface.discardPresentation(
        self.compositor.surfaceStore(),
        self.outputs.get(output.protocol_id).?,
    );
    requestRepaint(self);
}

fn commitTimingFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.terminate();
}

fn closeOutput(context: *anyopaque) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    output.server.terminate();
}

fn serverForOutput(context: *anyopaque) *Self {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    return output.server;
}

fn nativeKeyboardKeymap(context: *anyopaque, source: ?NativeInput.DeviceId, format: wl.Keyboard.KeymapFormat, fd: std.posix.fd_t, size: u32) void {
    const self = serverForOutput(context);
    const seat = if (source) |id| self.seatForDevice(id) else &self.seat;
    seat.setKeymap(format, fd, size);
}
fn nativeKeyboardKey(context: *anyopaque, id: NativeInput.DeviceId, time: u32, key: u32, state: wl.Keyboard.KeyState) void {
    const self = serverForOutput(context);
    self.routeKeyboardKey(id, time, key, state);
}
fn nativeKeyboardModifiers(context: *anyopaque, source: ?NativeInput.DeviceId, depressed: u32, latched: u32, locked: u32, group: u32) void {
    const self = serverForOutput(context);
    const seat = if (source) |id| self.seatForDevice(id) else &self.seat;
    seat.setModifiers(depressed, latched, locked, group);
}
fn nativeKeyboardRepeatInfo(context: *anyopaque, source: ?NativeInput.DeviceId, rate: i32, delay: i32) void {
    const self = serverForOutput(context);
    const seat = if (source) |id| self.seatForDevice(id) else &self.seat;
    seat.setRepeatInfo(rate, delay);
}
fn nativePointerMotion(context: *anyopaque, id: NativeInput.DeviceId, time: u32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    pointerMotionForSeat(output, output.server.seatForDevice(id), time, x, y);
}
fn nativePointerRelativeMotion(context: *anyopaque, id: NativeInput.DeviceId, time: u64, dx: f64, dy: f64, dx_unaccelerated: f64, dy_unaccelerated: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const seat = self.seatForDevice(id);
    if (seat == &self.seat) {
        self.relative_pointer.motion(time, dx, dy, dx_unaccelerated, dy_unaccelerated);
    }
    const current: RenderOutput.Point = if (seat.pointerPosition()) |position|
        .{ .x = position.x, .y = position.y }
    else initial: {
        const size = output.backend.size();
        break :initial output.globalPoint(
            @as(f64, @floatFromInt(size.width)) / 2,
            @as(f64, @floatFromInt(size.height)) / 2,
        );
    };
    const point = self.constrainPointerToOutputs(.{
        .x = current.x + dx,
        .y = current.y + dy,
    }) orelse return;
    self.pointerMotionGlobalForSeat(
        self.renderOutputAt(point.x, point.y),
        seat,
        @truncate(time / std.time.us_per_ms),
        point.x,
        point.y,
    );
}
fn nativePointerButton(context: *anyopaque, id: NativeInput.DeviceId, time: u32, button: u32, state: wl.Pointer.ButtonState) void {
    const self = serverForOutput(context);
    self.routePointerButton(id, time, button, state);
}
fn nativePointerAxis(context: *anyopaque, id: NativeInput.DeviceId, time: u32, axis: wl.Pointer.Axis, value: wl.Fixed) void {
    const self = serverForOutput(context);
    const seat = self.seatForDevice(id);
    self.idle_notify.notifyActivity(seat);
    seat.pointerAxis(time, axis, value);
}
fn nativePointerFrame(context: *anyopaque, id: NativeInput.DeviceId) void {
    serverForOutput(context).seatForDevice(id).pointerFrame();
}
fn nativePointerAxisSource(context: *anyopaque, id: NativeInput.DeviceId, source: wl.Pointer.AxisSource) void {
    serverForOutput(context).seatForDevice(id).pointerAxisSource(source);
}
fn nativePointerAxisStop(context: *anyopaque, id: NativeInput.DeviceId, time: u32, axis: wl.Pointer.Axis) void {
    serverForOutput(context).seatForDevice(id).pointerAxisStop(time, axis);
}
fn nativePointerAxisDiscrete(context: *anyopaque, id: NativeInput.DeviceId, axis: wl.Pointer.Axis, discrete: i32) void {
    serverForOutput(context).seatForDevice(id).pointerAxisDiscrete(axis, discrete);
}
fn nativePointerAxisValue120(context: *anyopaque, id: NativeInput.DeviceId, axis: wl.Pointer.Axis, value: i32) void {
    serverForOutput(context).seatForDevice(id).pointerAxisValue120(axis, value);
}
fn nativeSwipeBegin(context: *anyopaque, id: NativeInput.DeviceId, time: u32, fingers: u32) void {
    serverForOutput(context).beginGesture(id, time, fingers, .swipe);
}
fn nativeSwipeUpdate(context: *anyopaque, id: NativeInput.DeviceId, time: u32, dx: f64, dy: f64) void {
    const self = serverForOutput(context);
    const seat = self.gestureSeat(id, .swipe) orelse return;
    self.idle_notify.notifyActivity(seat);
    self.pointer_gestures.updateSwipe(seat, time, dx, dy);
}
fn nativeSwipeEnd(context: *anyopaque, id: NativeInput.DeviceId, time: u32, cancelled: bool) void {
    serverForOutput(context).endGesture(id, time, .swipe, cancelled);
}
fn nativePinchBegin(context: *anyopaque, id: NativeInput.DeviceId, time: u32, fingers: u32) void {
    serverForOutput(context).beginGesture(id, time, fingers, .pinch);
}
fn nativePinchUpdate(
    context: *anyopaque,
    id: NativeInput.DeviceId,
    time: u32,
    dx: f64,
    dy: f64,
    scale: f64,
    rotation: f64,
) void {
    const self = serverForOutput(context);
    const seat = self.gestureSeat(id, .pinch) orelse return;
    self.idle_notify.notifyActivity(seat);
    self.pointer_gestures.updatePinch(seat, time, dx, dy, scale, rotation);
}
fn nativePinchEnd(context: *anyopaque, id: NativeInput.DeviceId, time: u32, cancelled: bool) void {
    serverForOutput(context).endGesture(id, time, .pinch, cancelled);
}
fn nativeHoldBegin(context: *anyopaque, id: NativeInput.DeviceId, time: u32, fingers: u32) void {
    serverForOutput(context).beginGesture(id, time, fingers, .hold);
}
fn nativeHoldEnd(context: *anyopaque, id: NativeInput.DeviceId, time: u32, cancelled: bool) void {
    serverForOutput(context).endGesture(id, time, .hold, cancelled);
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
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const info = self.native_input.tabletToolInfo(tool_id) orelse return;
    const target = if (in_proximity) tabletFocus(output, x, y) else null;
    const routed_axes = tabletAxesRoute(output, axes).axes;
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.proximity(
        device_id,
        info,
        time,
        target,
        in_proximity,
        routed_axes,
    ) catch self.terminate();
}
fn nativeTabletToolAxis(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    tool_id: NativeInput.TabletToolId,
    time: u32,
    axes: NativeInput.TabletToolAxes,
) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const route = tabletAxesRoute(output, axes);
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.axis(device_id, tool_id, time, route.focus, route.axes);
}
fn nativeTabletToolTip(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    tool_id: NativeInput.TabletToolId,
    time: u32,
    axes: NativeInput.TabletToolAxes,
    down: bool,
) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const route = tabletAxesRoute(output, axes);
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.tip(device_id, tool_id, time, route.focus, route.axes, down);
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
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const route = tabletAxesRoute(output, axes);
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.button(
        device_id,
        tool_id,
        time,
        route.focus,
        route.axes,
        button,
        pressed,
    ) catch self.terminate();
}

fn nativeTabletPadButton(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    time: u32,
    button: u32,
    pressed: bool,
    group: u32,
    mode: u32,
) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.padButton(device_id, time, button, pressed, group, mode);
}

fn nativeTabletPadRing(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    time: u32,
    ring: u32,
    position: f64,
    finger: bool,
    group: u32,
    mode: u32,
) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.padRing(device_id, time, ring, position, finger, group, mode);
}

fn nativeTabletPadStrip(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    time: u32,
    strip: u32,
    position: f64,
    finger: bool,
    group: u32,
    mode: u32,
) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.padStrip(device_id, time, strip, position, finger, group, mode);
}

fn nativeTabletPadDial(
    context: *anyopaque,
    device_id: NativeInput.DeviceId,
    time: u32,
    dial: u32,
    value120: i32,
    group: u32,
    mode: u32,
) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(self.seatForDevice(device_id));
    self.tablet.padDial(device_id, time, dial, value120, group, mode);
}

const TabletAxisRoute = struct {
    axes: NativeInput.TabletToolAxes,
    focus: ?Seat.PointerFocus,
};

fn tabletAxesRoute(output: *RenderOutput, axes: NativeInput.TabletToolAxes) TabletAxisRoute {
    var routed = axes;
    const position = axes.position orelse return .{ .axes = routed, .focus = null };
    const point = output.globalPoint(position.x, position.y);
    routed.position = .{ .x = point.x, .y = point.y };
    return .{
        .axes = routed,
        .focus = output.server.pointerFocus(point.x, point.y),
    };
}

fn tabletFocus(output: *RenderOutput, x: f64, y: f64) ?Seat.PointerFocus {
    const point = output.globalPoint(x, y);
    return output.server.pointerFocus(point.x, point.y);
}

fn tabletSurfaceCoordinates(
    context: *anyopaque,
    surface_id: Surface.Id,
    x: f64,
    y: f64,
) ?Tablet.Point {
    const self: *Self = @ptrCast(@alignCast(context));
    const root = self.subcompositor.rootSurface(surface_id);
    const root_position = self.scene.surfacePosition(root) orelse return null;
    const offset = self.subcompositor.surfaceOffset(surface_id);
    return .{
        .x = x - @as(f64, @floatFromInt(root_position.x +| offset.x)),
        .y = y - @as(f64, @floatFromInt(root_position.y +| offset.y)),
    };
}
fn nativeTouchDown(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, id: i32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    output.server.routeTouchDown(output, device_id, time, id, x, y);
}
fn nativeTouchUp(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, id: i32) void {
    serverForOutput(context).routeTouchUp(device_id, time, id);
}
fn nativeTouchMotion(context: *anyopaque, device_id: NativeInput.DeviceId, time: u32, id: i32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    output.server.routeTouchMotion(output, device_id, time, id, x, y);
}
fn nativeTouchFrame(context: *anyopaque, device_id: NativeInput.DeviceId) void {
    const self = serverForOutput(context);
    const seat = self.touchSeatForDevice(device_id) orelse self.seatForDevice(device_id);
    seat.touchFrame();
}
fn nativeTouchCancel(context: *anyopaque, device_id: NativeInput.DeviceId) void {
    serverForOutput(context).cancelDeviceTouches(device_id);
}

fn routeKeyboardKey(
    self: *Self,
    device_id: NativeInput.DeviceId,
    time: u32,
    key: u32,
    state: wl.Keyboard.KeyState,
) void {
    const seat = self.seatForDevice(device_id);
    self.idle_notify.notifyActivity(seat);
    if (state == .pressed and self.window_transitions.items.len != 0) {
        finishAllWindowTransitions(self);
        requestRepaint(self);
    }
    switch (state) {
        .pressed => {
            for (self.routed_keys.items) |routed| {
                if (routed.device_id == device_id and routed.key == key) return;
            }
            const already_pressed = self.seatKeyHeld(seat, key);
            self.routed_keys.append(self.allocator, .{
                .device_id = device_id,
                .seat = seat,
                .key = key,
            }) catch return self.terminate();
            if (already_pressed) return;
        },
        .released => {
            for (self.routed_keys.items, 0..) |routed, index| {
                if (routed.device_id != device_id or routed.key != key) continue;
                _ = self.routed_keys.orderedRemove(index);
                if (self.seatKeyHeld(routed.seat, key)) return;
                routed.seat.key(time, key, state) catch return self.terminate();
                return;
            }
            return;
        },
        .repeated => {},
        else => return,
    }
    seat.key(time, key, state) catch self.terminate();
}

fn releaseDeviceKeys(self: *Self, device_id: NativeInput.DeviceId) void {
    var index: usize = 0;
    while (index < self.routed_keys.items.len) {
        const routed = self.routed_keys.items[index];
        if (routed.device_id != device_id) {
            index += 1;
            continue;
        }
        _ = self.routed_keys.orderedRemove(index);
        if (self.seatKeyHeld(routed.seat, routed.key)) continue;
        routed.seat.key(0, routed.key, .released) catch return self.terminate();
    }
}

fn seatKeyHeld(self: *const Self, seat: *Seat, key: u32) bool {
    for (self.routed_keys.items) |routed| {
        if (routed.seat == seat and routed.key == key) return true;
    }
    return false;
}

fn routePointerButton(
    self: *Self,
    device_id: NativeInput.DeviceId,
    time: u32,
    button: u32,
    state: wl.Pointer.ButtonState,
) void {
    const seat = self.seatForDevice(device_id);
    self.routePointerButtonFromSource(.{ .native = device_id }, seat, time, button, state);
}

fn routePointerButtonFromSource(
    self: *Self,
    source: PointerButtonSource,
    seat: *Seat,
    time: u32,
    button: u32,
    state: wl.Pointer.ButtonState,
) void {
    self.idle_notify.notifyActivity(seat);
    if (state == .pressed and self.window_transitions.items.len != 0) {
        finishAllWindowTransitions(self);
        requestRepaint(self);
    }
    switch (state) {
        .pressed => {
            for (self.routed_buttons.items) |routed| {
                if (std.meta.eql(routed.source, source) and routed.button == button) return;
            }
            const already_pressed = self.seatButtonHeld(seat, button);
            self.routed_buttons.append(self.allocator, .{
                .source = source,
                .seat = seat,
                .button = button,
            }) catch return self.terminate();
            if (already_pressed) return;
        },
        .released => {
            for (self.routed_buttons.items, 0..) |routed, index| {
                if (!std.meta.eql(routed.source, source) or routed.button != button) continue;
                _ = self.routed_buttons.orderedRemove(index);
                if (self.seatButtonHeld(routed.seat, button)) return;
                self.pointerButtonForSeat(routed.seat, time, button, state);
                return;
            }
            return;
        },
        else => return,
    }
    self.pointerButtonForSeat(seat, time, button, state);
}

fn releaseDeviceButtons(self: *Self, device_id: NativeInput.DeviceId) void {
    var index: usize = 0;
    while (index < self.routed_buttons.items.len) {
        const routed = self.routed_buttons.items[index];
        const matches = switch (routed.source) {
            .native => |candidate| candidate == device_id,
            .virtual => false,
        };
        if (!matches) {
            index += 1;
            continue;
        }
        _ = self.routed_buttons.orderedRemove(index);
        if (self.seatButtonHeld(routed.seat, routed.button)) continue;
        self.pointerButtonForSeat(routed.seat, 0, routed.button, .released);
    }
}

fn seatButtonHeld(self: *const Self, seat: *Seat, button: u32) bool {
    for (self.routed_buttons.items) |routed| {
        if (routed.seat == seat and routed.button == button) return true;
    }
    return false;
}

fn forgetRoutedButtonsForSeat(self: *Self, seat: *Seat) void {
    var index: usize = 0;
    while (index < self.routed_buttons.items.len) {
        if (self.routed_buttons.items[index].seat != seat) {
            index += 1;
            continue;
        }
        _ = self.routed_buttons.orderedRemove(index);
    }
}

fn beginGesture(
    self: *Self,
    device_id: NativeInput.DeviceId,
    time: u32,
    fingers: u32,
    kind: GestureKind,
) void {
    const seat = self.seatForDevice(device_id);
    var index: usize = 0;
    while (index < self.routed_gestures.items.len) {
        const routed = self.routed_gestures.items[index];
        if (routed.device_id == device_id or routed.seat == seat) {
            self.cancelRoutedGesture(index);
        } else {
            index += 1;
        }
    }
    self.routed_gestures.append(self.allocator, .{
        .device_id = device_id,
        .seat = seat,
        .kind = kind,
    }) catch return self.terminate();
    self.idle_notify.notifyActivity(seat);
    switch (kind) {
        .swipe => self.pointer_gestures.beginSwipe(seat, time, fingers),
        .pinch => self.pointer_gestures.beginPinch(seat, time, fingers),
        .hold => self.pointer_gestures.beginHold(seat, time, fingers),
    }
}

fn endGesture(
    self: *Self,
    device_id: NativeInput.DeviceId,
    time: u32,
    kind: GestureKind,
    cancelled: bool,
) void {
    for (self.routed_gestures.items, 0..) |routed, index| {
        if (routed.device_id != device_id or routed.kind != kind) continue;
        _ = self.routed_gestures.orderedRemove(index);
        self.idle_notify.notifyActivity(routed.seat);
        self.sendGestureEnd(routed.seat, time, kind, cancelled);
        return;
    }
}

fn gestureSeat(self: *const Self, device_id: NativeInput.DeviceId, kind: GestureKind) ?*Seat {
    for (self.routed_gestures.items) |routed| {
        if (routed.device_id == device_id and routed.kind == kind) return routed.seat;
    }
    return null;
}

fn cancelDeviceGestures(self: *Self, device_id: NativeInput.DeviceId) void {
    var index: usize = 0;
    while (index < self.routed_gestures.items.len) {
        if (self.routed_gestures.items[index].device_id == device_id) {
            self.cancelRoutedGesture(index);
        } else {
            index += 1;
        }
    }
}

fn cancelSeatGestures(self: *Self, seat: *Seat) void {
    var index: usize = 0;
    while (index < self.routed_gestures.items.len) {
        if (self.routed_gestures.items[index].seat == seat) {
            self.cancelRoutedGesture(index);
        } else {
            index += 1;
        }
    }
}

fn cancelRoutedGesture(self: *Self, index: usize) void {
    const routed = self.routed_gestures.orderedRemove(index);
    self.sendGestureEnd(routed.seat, 0, routed.kind, true);
}

fn sendGestureEnd(
    self: *Self,
    seat: *Seat,
    time: u32,
    kind: GestureKind,
    cancelled: bool,
) void {
    switch (kind) {
        .swipe => self.pointer_gestures.endSwipe(seat, time, cancelled),
        .pinch => self.pointer_gestures.endPinch(seat, time, cancelled),
        .hold => self.pointer_gestures.endHold(seat, time, cancelled),
    }
}

fn routeTouchDown(
    self: *Self,
    output: *RenderOutput,
    device_id: NativeInput.DeviceId,
    time: u32,
    native_id: i32,
    x: f64,
    y: f64,
) void {
    for (self.routed_touches.items) |touch| {
        if (touch.device_id == device_id and touch.native_id == native_id) return;
    }
    if (self.window_transitions.items.len != 0) {
        finishAllWindowTransitions(self);
        requestRepaint(self);
    }
    const seat = self.seatForDevice(device_id);
    self.idle_notify.notifyActivity(seat);
    const protocol_id = self.allocateTouchId(seat);
    self.routed_touches.append(self.allocator, .{
        .device_id = device_id,
        .native_id = native_id,
        .seat = seat,
        .protocol_id = protocol_id,
    }) catch return self.terminate();

    const point = output.globalPoint(x, y);
    const focus = self.pointerFocus(point.x, point.y);
    if (self.session_lock.isLocked()) {
        if (focus) |target| {
            self.session_lock.pointerPressed(self.subcompositor.rootSurface(target.surface_id));
        }
    } else if (seat == &self.seat) {
        if (focus) |target| {
            const root = self.subcompositor.rootSurface(target.surface_id);
            self.window_manager.pointerButton(root, .pressed);
            self.layer_shell.pointerPressed(root);
            requestRepaint(self);
        } else {
            self.window_manager.pointerButton(null, .pressed);
            if (self.xdg_shell.hasPopupGrab()) self.xdg_shell.dismissPopupGrab();
        }
    }
    seat.touchDown(time, protocol_id, point.x, point.y, focus) catch {
        _ = self.routed_touches.pop();
        self.terminate();
    };
}

fn routeTouchUp(self: *Self, device_id: NativeInput.DeviceId, time: u32, native_id: i32) void {
    for (self.routed_touches.items, 0..) |touch, index| {
        if (touch.device_id != device_id or touch.native_id != native_id) continue;
        self.idle_notify.notifyActivity(touch.seat);
        _ = self.routed_touches.orderedRemove(index);
        touch.seat.touchUp(time, touch.protocol_id) catch self.terminate();
        return;
    }
}

fn routeTouchMotion(
    self: *Self,
    output: *RenderOutput,
    device_id: NativeInput.DeviceId,
    time: u32,
    native_id: i32,
    x: f64,
    y: f64,
) void {
    for (self.routed_touches.items) |touch| {
        if (touch.device_id != device_id or touch.native_id != native_id) continue;
        self.idle_notify.notifyActivity(touch.seat);
        const point = output.globalPoint(x, y);
        touch.seat.touchMotion(time, touch.protocol_id, point.x, point.y) catch self.terminate();
        return;
    }
}

fn cancelDeviceTouches(self: *Self, device_id: NativeInput.DeviceId) void {
    var index: usize = 0;
    while (index < self.routed_touches.items.len) {
        if (self.routed_touches.items[index].device_id == device_id) {
            const touch = self.routed_touches.orderedRemove(index);
            touch.seat.touchCancelPoint(touch.protocol_id);
        } else {
            index += 1;
        }
    }
}

fn cancelSeatTouches(self: *Self, seat: *Seat) void {
    seat.touchCancel();
    var index: usize = 0;
    while (index < self.routed_touches.items.len) {
        if (self.routed_touches.items[index].seat == seat) {
            _ = self.routed_touches.orderedRemove(index);
        } else {
            index += 1;
        }
    }
}

fn touchSeatForDevice(self: *Self, device_id: NativeInput.DeviceId) ?*Seat {
    for (self.routed_touches.items) |touch| {
        if (touch.device_id == device_id) return touch.seat;
    }
    return null;
}

fn allocateTouchId(self: *Self, seat: *Seat) i32 {
    while (true) {
        const id: i32 = @intCast(self.next_touch_id);
        self.next_touch_id +%= 1;
        for (self.routed_touches.items) |touch| {
            if (touch.seat == seat and touch.protocol_id == id) break;
        } else return id;
    }
}

fn keyboardAvailable(context: *anyopaque, available: bool) void {
    const self = serverForOutput(context);
    self.seat.setKeyboardAvailable(available);
}

fn keyboardKeymap(
    context: *anyopaque,
    format: wl.Keyboard.KeymapFormat,
    fd: std.posix.fd_t,
    size: u32,
) void {
    const self = serverForOutput(context);
    self.seat.setKeymap(format, fd, size);
}

fn keyboardEnter(context: *anyopaque, pressed_keys: []const u32) void {
    const self = serverForOutput(context);
    self.seat.parentKeyboardEnter(pressed_keys) catch {
        log.err("failed to store pressed keyboard keys", .{});
        self.terminate();
    };
}

fn keyboardLeave(context: *anyopaque) void {
    const self = serverForOutput(context);
    self.seat.parentKeyboardLeave();
}

fn keyboardKey(
    context: *anyopaque,
    time: u32,
    key: u32,
    state: wl.Keyboard.KeyState,
) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(&self.seat);
    if (state == .pressed and self.window_transitions.items.len != 0) {
        finishAllWindowTransitions(self);
        requestRepaint(self);
    }
    self.seat.key(time, key, state) catch {
        log.err("failed to store keyboard state", .{});
        self.terminate();
    };
}

fn keyboardModifiers(
    context: *anyopaque,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) void {
    const self = serverForOutput(context);
    self.seat.setModifiers(depressed, latched, locked, group);
}

fn keyboardRepeatInfo(context: *anyopaque, rate: i32, delay: i32) void {
    const self = serverForOutput(context);
    self.seat.setRepeatInfo(rate, delay);
}

fn pointerAvailable(context: *anyopaque, available: bool) void {
    const self = serverForOutput(context);
    if (!available and self.window_manager_initialized) {
        self.pointer_constraints.deactivateAll();
        self.data_device.cancel();
    }
    self.seat.setPointerAvailable(available);
}

fn pointerEnter(context: *anyopaque, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    const point = output.globalPoint(x, y);
    const route = self.pointerRoute(point.x, point.y);
    if (self.session_lock.isLocked()) {
        self.seat.pointerEnter(point.x, point.y, route.focus);
        return;
    }
    if (self.window_manager.compositorPointerGrabActive()) {
        self.seat.pointerEnter(point.x, point.y, null);
        if (self.window_manager.updateCompositorPointerGrab(point.x, point.y)) requestRepaint(self);
        return;
    }
    if (self.data_device.isDragging()) {
        self.pointer_constraints.deactivateAll();
        self.seat.pointerEnter(
            point.x,
            point.y,
            self.data_device.externalDragPointerFocus(point.x, point.y),
        );
        self.xdg_toplevel_drag.pointerMotion(point.x, point.y);
        self.routeActiveDrag(0, self.dragPointerRoute(point.x, point.y), point.x, point.y, false);
        return;
    }
    self.seat.pointerEnter(point.x, point.y, route.focus);
    if (self.seat.implicitPointerGrabActive()) return;
    if (!self.xdg_shell.hasPopupGrab()) {
        self.window_manager.pointerMoved(route.root);
        self.updateResizeCursor(route.root, point.x, point.y);
    } else {
        self.seat.setCompositorCursor(null);
    }
    self.pointer_constraints.syncFocus();
}

fn pointerLeave(context: *anyopaque) void {
    const self = serverForOutput(context);
    if (self.endCompositorPointerGrab(false)) requestRepaint(self);
    self.seat.setCompositorCursor(null);
    self.pointer_constraints.deactivateAll();
    self.data_device.pointerLeft();
    if (self.xwm_initialized) self.xwm.dragLeft();
    self.forgetRoutedButtonsForSeat(&self.seat);
    self.seat.pointerLeave();
}

fn pointerMotion(context: *anyopaque, time: u32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    pointerMotionForSeat(output, &output.server.seat, time, x, y);
}

fn pointerMotionForSeat(output: *RenderOutput, seat: *Seat, time: u32, x: f64, y: f64) void {
    const self = output.server;
    const target = output.globalPoint(x, y);
    self.pointerMotionGlobalForSeat(output, seat, time, target.x, target.y);
}

fn pointerMotionGlobalForSeat(
    self: *Self,
    backend_output: ?*RenderOutput,
    seat: *Seat,
    time: u32,
    x: f64,
    y: f64,
) void {
    self.idle_notify.notifyActivity(seat);
    if (self.session_lock.isLocked()) {
        seat.pointerMotion(
            time,
            x,
            y,
            self.pointerFocus(x, y),
        );
        return;
    }
    if (seat == &self.seat and self.window_manager.compositorPointerGrabActive()) {
        self.pointer_constraints.deactivateAll();
        seat.pointerMotion(time, x, y, null);
        if (self.window_manager.updateCompositorPointerGrab(x, y)) requestRepaint(self);
        return;
    }
    if (seat == &self.seat and self.data_device.isDragging()) {
        self.pointer_constraints.deactivateAll();
        seat.pointerMotion(
            time,
            x,
            y,
            self.data_device.externalDragPointerFocus(x, y),
        );
        self.xdg_toplevel_drag.pointerMotion(x, y);
        self.routeActiveDrag(
            time,
            self.dragPointerRoute(x, y),
            x,
            y,
            true,
        );
        return;
    }
    if (seat != &self.seat) {
        const route = self.pointerRoute(x, y);
        seat.pointerMotion(time, x, y, route.focus);
        return;
    }
    const motion = self.pointer_constraints.constrainMotion(.{ .x = x, .y = y });
    if (motion.point.x != x or motion.point.y != y) {
        if (backend_output != null) {
            self.synchronizeBackendPointer(
                self.renderOutputAt(motion.point.x, motion.point.y),
                motion.point.x,
                motion.point.y,
            );
        }
    }
    if (motion.locked) return;
    const route = self.pointerRoute(motion.point.x, motion.point.y);
    seat.pointerMotion(
        time,
        motion.point.x,
        motion.point.y,
        route.focus,
    );
    if (seat.implicitPointerGrabActive()) return;
    if (!self.xdg_shell.hasPopupGrab()) {
        self.window_manager.pointerMoved(route.root);
        self.updateResizeCursor(route.root, motion.point.x, motion.point.y);
    } else {
        self.seat.setCompositorCursor(null);
    }
    self.pointer_constraints.syncFocus();
}

const VirtualPointerBounds = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    output: ?*RenderOutput,
};

fn virtualPointerBounds(
    self: *Self,
    mapped_output: ?OutputLayout.Id,
) ?VirtualPointerBounds {
    if (mapped_output) |output_id| {
        if (self.findProtocolRenderOutput(output_id)) |render_output| {
            const output = self.outputs.get(output_id) orelse return null;
            const position = output.logicalPosition();
            const size = output.logicalSize();
            return .{
                .x = @floatFromInt(position.x),
                .y = @floatFromInt(position.y),
                .width = @floatFromInt(size.width),
                .height = @floatFromInt(size.height),
                .output = render_output,
            };
        }
    }

    var left: ?i64 = null;
    var top: ?i64 = null;
    var right: ?i64 = null;
    var bottom: ?i64 = null;
    var outputs = self.outputs.iterator();
    while (outputs.next()) |entry| {
        const position = entry.output.logicalPosition();
        const size = entry.output.logicalSize();
        left = @min(left orelse position.x, position.x);
        top = @min(top orelse position.y, position.y);
        const output_right = @as(i64, position.x) + size.width;
        const output_bottom = @as(i64, position.y) + size.height;
        right = @max(right orelse output_right, output_right);
        bottom = @max(bottom orelse output_bottom, output_bottom);
    }
    const x = left orelse return null;
    const y = top orelse return null;
    return .{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(right.? - x),
        .height = @floatFromInt(bottom.? - y),
        .output = null,
    };
}

fn renderOutputAt(self: *Self, x: f64, y: f64) *RenderOutput {
    var outputs = self.render_outputs.iterator();
    while (outputs.next()) |entry| {
        const output = entry.value.*;
        const protocol_output = self.outputs.get(output.protocol_id) orelse continue;
        if (window_geometry.pointInRect(x, y, protocol_output.logicalRect())) return output;
    }
    return self.primaryRenderOutput();
}

fn constrainPointerToOutputs(self: *Self, point: RenderOutput.Point) ?RenderOutput.Point {
    std.debug.assert(std.math.isFinite(point.x) and std.math.isFinite(point.y));
    var closest: ?RenderOutput.Point = null;
    var closest_distance: ?f64 = null;
    var outputs = self.outputs.iterator();
    while (outputs.next()) |entry| {
        const rect = entry.output.logicalRect();
        std.debug.assert(rect.width > 0 and rect.height > 0);
        const left: f64 = @floatFromInt(rect.x);
        const top: f64 = @floatFromInt(rect.y);
        const right = left + @as(f64, @floatFromInt(rect.width - 1));
        const bottom = top + @as(f64, @floatFromInt(rect.height - 1));
        const candidate: RenderOutput.Point = .{
            .x = std.math.clamp(point.x, left, right),
            .y = std.math.clamp(point.y, top, bottom),
        };
        const dx = candidate.x - point.x;
        const dy = candidate.y - point.y;
        const distance = dx * dx + dy * dy;
        if (distance == 0) return point;
        if (closest_distance == null or distance < closest_distance.?) {
            closest = candidate;
            closest_distance = distance;
        }
    }
    return closest;
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
    const position = @as(f64, @floatFromInt(@min(value, extent))) /
        @as(f64, @floatFromInt(extent));
    return origin + position * (dimension - 1);
}

fn virtualPointerEvent(
    context: *anyopaque,
    seat: *Seat,
    mapped_output: ?OutputLayout.Id,
    source: u64,
    event: VirtualPointer.Event,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    switch (event) {
        .motion => |motion| {
            const bounds = self.virtualPointerBounds(mapped_output) orelse return;
            if (seat == &self.seat) {
                self.relative_pointer.motion(
                    @as(u64, motion.time) * std.time.us_per_ms,
                    motion.dx,
                    motion.dy,
                    motion.dx,
                    motion.dy,
                );
            }
            const current = seat.pointerPosition();
            const current_x = if (current) |point| point.x else bounds.x;
            const current_y = if (current) |point| point.y else bounds.y;
            const x = clampVirtualPointerCoordinate(current_x + motion.dx, bounds.x, bounds.width);
            const y = clampVirtualPointerCoordinate(current_y + motion.dy, bounds.y, bounds.height);
            self.pointerMotionGlobalForSeat(
                bounds.output orelse self.renderOutputAt(x, y),
                seat,
                motion.time,
                x,
                y,
            );
        },
        .motion_absolute => |motion| {
            if (motion.x_extent == 0 or motion.y_extent == 0) return;
            const bounds = self.virtualPointerBounds(mapped_output) orelse return;
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
            self.pointerMotionGlobalForSeat(
                bounds.output orelse self.renderOutputAt(x, y),
                seat,
                motion.time,
                x,
                y,
            );
        },
        .button => |button| self.routePointerButtonFromSource(
            .{ .virtual = source },
            seat,
            button.time,
            button.button,
            button.state,
        ),
        .axis => |axis| {
            self.idle_notify.notifyActivity(seat);
            seat.pointerAxis(axis.time, axis.axis, axis.value);
        },
        .frame => seat.pointerFrame(),
        .axis_source => |axis_source| seat.pointerAxisSource(axis_source),
        .axis_stop => |stop| seat.pointerAxisStop(stop.time, stop.axis),
        .axis_discrete => |axis| {
            self.idle_notify.notifyActivity(seat);
            seat.pointerAxisDiscrete(axis.axis, axis.discrete);
            seat.pointerAxisValue120(axis.axis, axis.discrete *| 120);
            seat.pointerAxis(axis.time, axis.axis, axis.value);
        },
    }
}

fn synchronizeBackendPointer(self: *Self, output: *RenderOutput, x: f64, y: f64) void {
    if (!self.native_input_initialized) return;
    const position = self.outputs.get(output.protocol_id).?.logicalPosition();
    self.native_input.setPointerPosition(
        x - @as(f64, @floatFromInt(position.x)),
        y - @as(f64, @floatFromInt(position.y)),
    );
}

fn pointerWarp(context: *anyopaque, surface_id: Surface.Id, x: f64, y: f64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const position = self.seat.warpPointer(surface_id, x, y) orelse return;
    self.synchronizeBackendPointer(
        self.renderOutputAt(position.x, position.y),
        position.x,
        position.y,
    );
}

fn pointerRelativeMotion(
    context: *anyopaque,
    time_usec: u64,
    dx: f64,
    dy: f64,
    dx_unaccelerated: f64,
    dy_unaccelerated: f64,
) void {
    const self = serverForOutput(context);
    self.relative_pointer.motion(time_usec, dx, dy, dx_unaccelerated, dy_unaccelerated);
}

fn pointerButton(
    context: *anyopaque,
    time: u32,
    button: u32,
    state: wl.Pointer.ButtonState,
) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(&self.seat);
    self.pointerButtonForSeat(&self.seat, time, button, state);
}

fn pointerButtonForSeat(
    self: *Self,
    seat: *Seat,
    time: u32,
    button: u32,
    state: wl.Pointer.ButtonState,
) void {
    if (self.session_lock.isLocked()) {
        if (state == .pressed) {
            const focused = if (seat.pointerFocusedSurface()) |surface_id|
                self.subcompositor.rootSurface(surface_id)
            else
                null;
            self.session_lock.pointerPressed(focused);
        }
        const grab_ended = seat.pointerButton(time, button, state) catch {
            log.err("failed to store pointer button state", .{});
            self.terminate();
            return;
        };
        if (state == .released and grab_ended) self.restoreSeatPointerFocus(seat);
        return;
    }
    if (seat == &self.seat and self.data_device.isDragging()) {
        const grab_ended = seat.pointerButton(time, button, state) catch {
            log.err("failed to store pointer button state", .{});
            self.terminate();
            return;
        };
        if (state == .released and grab_ended) {
            if (!self.xwm_initialized or !self.xwm.dropDrag(time)) self.data_device.drop();
        }
        return;
    }
    if (seat == &self.seat and self.window_manager.compositorPointerGrabActive()) {
        if (button == linux_button_left and state == .released) {
            const position = seat.pointerPosition();
            if (position) |point| {
                _ = self.window_manager.updateCompositorPointerGrab(point.x, point.y);
            }
            _ = self.endCompositorPointerGrab(true);
            if (position) |point| {
                const route = self.pointerRoute(point.x, point.y);
                seat.pointerEnter(point.x, point.y, route.focus);
                self.updateResizeCursor(route.root, point.x, point.y);
                self.pointer_constraints.syncFocus();
            }
            requestRepaint(self);
        } else {
            _ = seat.pointerButton(time, button, state) catch {
                log.err("failed to store pointer button state", .{});
                self.terminate();
            };
        }
        return;
    }
    const root = if (seat.implicitPointerGrabActive())
        if (seat.pointerFocusedSurface()) |surface_id|
            self.subcompositor.rootSurface(surface_id)
        else
            null
    else if (seat.pointerPosition()) |position|
        self.pointerRoute(position.x, position.y).root
    else
        null;
    if (seat == &self.seat and button == linux_button_left and state == .pressed and
        !seat.hasPressedPointerButtons() and !self.xdg_shell.hasPopupGrab())
    {
        if (seat.pointerPosition()) |position| {
            const modifier_move = seat.effectiveModifiers() & Config.super != 0 and
                !self.keyboard_shortcuts_inhibit.inhibitsSeatNamed(InputManager.default_seat_name);
            const started = if (modifier_move)
                self.window_manager.beginModifierMove(root, position.x, position.y)
            else
                self.window_manager.beginInteractiveResize(root, position.x, position.y);
            if (started) {
                self.pointer_constraints.deactivateAll();
                seat.suppressPointerFocus(true);
                seat.setCompositorCursor(if (self.window_manager.interactiveResizeCursorShape()) |shape|
                    self.cursor_shape.cursorImage(shape)
                else
                    null);
                _ = self.window_manager.updateCompositorPointerGrab(position.x, position.y);
                requestRepaint(self);
                return;
            }
        }
    }
    self.window_manager.pointerButton(root, state);
    if (state == .pressed) {
        const focused = if (seat.pointerFocusedSurface()) |surface_id|
            self.subcompositor.rootSurface(surface_id)
        else
            null;
        if (seat == &self.seat) self.layer_shell.pointerPressed(focused);
        requestRepaint(self);
    }
    if (seat == &self.seat and state == .pressed and self.xdg_shell.hasPopupGrab() and
        seat.pointerFocusedSurface() == null)
    {
        self.xdg_shell.dismissPopupGrab();
        return;
    }
    const grab_ended = seat.pointerButton(time, button, state) catch {
        log.err("failed to store pointer button state", .{});
        self.terminate();
        return;
    };
    if (state == .released and grab_ended) self.restoreSeatPointerFocus(seat);
}

fn dragStarted(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.endCompositorPointerGrab(false)) requestRepaint(self);
    self.seat.setCompositorCursor(null);
    self.pointer_constraints.deactivateAll();
    if (self.xwm_initialized) self.xwm.dragStarted();
    self.reconcileOutputCursors();
    self.seat.dissolvePointerGrab();
    const position = self.seat.pointerPosition() orelse return;
    const route = self.dragPointerRoute(position.x, position.y);
    if (!self.data_device.dragIsExternal()) self.seat.suppressPointerFocus(true);
    self.routeActiveDrag(0, route, position.x, position.y, false);
}

fn endCompositorPointerGrab(self: *Self, commit: bool) bool {
    const ended = self.window_manager.endCompositorPointerGrab(commit);
    if (ended) self.seat.setCompositorCursor(null);
    return ended;
}

fn updateResizeCursor(self: *Self, root: ?Surface.Id, x: f64, y: f64) void {
    if (!self.window_manager_initialized) {
        self.seat.setCompositorCursor(null);
        return;
    }
    const shape = self.window_manager.resizeCursorShapeAt(root, x, y) orelse {
        self.seat.setCompositorCursor(null);
        return;
    };
    self.seat.setCompositorCursor(self.cursor_shape.cursorImage(shape));
}

fn xdgToplevelDragBegin(
    context: *anyopaque,
    window_id: XdgShell.WindowId,
    pointer_x: f64,
    pointer_y: f64,
    x_offset: i32,
    y_offset: i32,
    use_offset_hint: bool,
) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.window_manager.beginToplevelDrag(
        window_id,
        pointer_x,
        pointer_y,
        x_offset,
        y_offset,
        use_offset_hint,
    );
}

fn xdgToplevelDragMotion(context: *anyopaque, x: f64, y: f64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.window_manager.updateToplevelDrag(x, y);
}

fn xdgToplevelDragEnd(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.window_manager.endToplevelDrag();
}

fn dragEnded(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwm_initialized) self.xwm.physicalDragEnded();
    self.reconcileOutputCursors();
    self.restoreSeatPointerFocus(&self.seat);
}

fn restoreSeatPointerFocus(self: *Self, seat: *Seat) void {
    const position = seat.pointerPosition() orelse return;
    const route = self.pointerRoute(position.x, position.y);
    seat.pointerEnter(position.x, position.y, route.focus);
    if (seat != &self.seat or self.session_lock.isLocked()) return;
    if (!self.xdg_shell.hasPopupGrab()) {
        self.window_manager.pointerMoved(route.root);
        self.updateResizeCursor(route.root, position.x, position.y);
    }
    self.pointer_constraints.syncFocus();
}

fn dragExternalSourceDestroyed(context: *anyopaque, generation: u64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwm_initialized) self.xwm.dragSourceDestroyed(generation);
}

fn routeActiveDrag(
    self: *Self,
    time: u32,
    route: PointerRoute,
    x: f64,
    y: f64,
    motion: bool,
) void {
    if (self.xwm_initialized) {
        if (self.data_device.dragIsExternal()) {
            if (route.root) |surface_id| if (self.xwaylandWindowForSurface(surface_id) != null) {
                self.data_device.pointerLeft();
                self.xwm.routeExternalDragOverXwayland(true);
                return;
            };
            self.xwm.routeExternalDragOverXwayland(false);
        } else {
            if (route.root) |surface_id| if (self.xwaylandWindowForSurface(surface_id)) |window_id| {
                self.data_device.pointerLeft();
                self.xwm.dragMotion(window_id, time, x, y);
                return;
            };
            self.xwm.dragLeft();
        }
    }
    if (motion) {
        self.data_device.pointerMotion(time, route.focus);
    } else {
        self.data_device.pointerEntered(route.focus);
    }
}

fn pointerAxis(context: *anyopaque, time: u32, axis: wl.Pointer.Axis, value: wl.Fixed) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(&self.seat);
    self.seat.pointerAxis(time, axis, value);
}

fn pointerFrame(context: *anyopaque) void {
    const self = serverForOutput(context);
    self.seat.pointerFrame();
}

fn pointerAxisSource(context: *anyopaque, source: wl.Pointer.AxisSource) void {
    const self = serverForOutput(context);
    self.seat.pointerAxisSource(source);
}

fn pointerAxisStop(context: *anyopaque, time: u32, axis: wl.Pointer.Axis) void {
    const self = serverForOutput(context);
    self.seat.pointerAxisStop(time, axis);
}

fn pointerAxisDiscrete(context: *anyopaque, axis: wl.Pointer.Axis, discrete: i32) void {
    const self = serverForOutput(context);
    self.seat.pointerAxisDiscrete(axis, discrete);
}

fn pointerAxisValue120(context: *anyopaque, axis: wl.Pointer.Axis, value120: i32) void {
    const self = serverForOutput(context);
    self.seat.pointerAxisValue120(axis, value120);
}

fn pointerAxisRelativeDirection(
    context: *anyopaque,
    axis: wl.Pointer.Axis,
    direction: wl.Pointer.AxisRelativeDirection,
) void {
    const self = serverForOutput(context);
    self.seat.pointerAxisRelativeDirection(axis, direction);
}

fn touchAvailable(context: *anyopaque, available: bool) void {
    const self = serverForOutput(context);
    self.seat.setTouchAvailable(available);
}

fn touchDown(context: *anyopaque, time: u32, id: i32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    if (self.window_transitions.items.len != 0) {
        finishAllWindowTransitions(self);
        requestRepaint(self);
    }
    self.idle_notify.notifyActivity(&self.seat);
    const point = output.globalPoint(x, y);
    const focus = self.pointerFocus(point.x, point.y);
    if (self.session_lock.isLocked()) {
        if (focus) |target| {
            self.session_lock.pointerPressed(self.subcompositor.rootSurface(target.surface_id));
        }
        self.seat.touchDown(time, id, point.x, point.y, focus) catch {
            log.err("failed to store touch point", .{});
            self.terminate();
        };
        return;
    }
    if (focus) |target| {
        const root = self.subcompositor.rootSurface(target.surface_id);
        self.window_manager.pointerButton(root, .pressed);
        self.layer_shell.pointerPressed(root);
        requestRepaint(self);
    } else {
        self.window_manager.pointerButton(null, .pressed);
        if (self.xdg_shell.hasPopupGrab()) self.xdg_shell.dismissPopupGrab();
    }
    self.seat.touchDown(time, id, point.x, point.y, focus) catch {
        log.err("failed to store touch point", .{});
        self.terminate();
    };
}

fn touchUp(context: *anyopaque, time: u32, id: i32) void {
    const self = serverForOutput(context);
    self.idle_notify.notifyActivity(&self.seat);
    self.seat.touchUp(time, id) catch {
        log.err("failed to finish touch point", .{});
        self.terminate();
    };
}

fn touchMotion(context: *anyopaque, time: u32, id: i32, x: f64, y: f64) void {
    const output: *RenderOutput = @ptrCast(@alignCast(context));
    const self = output.server;
    self.idle_notify.notifyActivity(&self.seat);
    const point = output.globalPoint(x, y);
    self.seat.touchMotion(time, id, point.x, point.y) catch {
        log.err("failed to update touch point", .{});
        self.terminate();
    };
}

fn touchFrame(context: *anyopaque) void {
    const self = serverForOutput(context);
    self.seat.touchFrame();
}

fn touchCancel(context: *anyopaque) void {
    const self = serverForOutput(context);
    self.seat.touchCancel();
}

fn touchShape(context: *anyopaque, id: i32, major: f64, minor: f64) void {
    const self = serverForOutput(context);
    self.seat.touchShape(id, major, minor) catch {
        log.err("failed to update touch shape", .{});
        self.terminate();
    };
}

fn touchOrientation(context: *anyopaque, id: i32, orientation: f64) void {
    const self = serverForOutput(context);
    self.seat.touchOrientation(id, orientation) catch {
        log.err("failed to update touch orientation", .{});
        self.terminate();
    };
}

fn pointerFocus(self: *Self, x: f64, y: f64) ?Seat.PointerFocus {
    return self.pointerFocusExcluding(x, y, null);
}

fn pointerFocusExcluding(
    self: *Self,
    x: f64,
    y: f64,
    excluded_window: ?Scene.Id,
) ?Seat.PointerFocus {
    if (self.session_lock.isLocked()) {
        var outputs = self.outputs.iterator();
        while (outputs.next()) |entry| {
            if (!window_geometry.pointInRect(x, y, entry.output.logicalRect())) continue;
            const info = self.session_lock.surfaceForOutput(entry.id) orelse return null;
            return self.hitTestSurface(info.surface_id, .{
                .x = info.position.x,
                .y = info.position.y,
            }, x, y);
        }
        return null;
    }
    const focus = self.scenePointerFocus(x, y, excluded_window);
    if (focus) |candidate| {
        if (self.xdg_shell.hasPopupGrab() and
            !self.xdg_shell.popupGrabOwnsSurface(candidate.surface_id)) return null;
    }
    return focus;
}

fn pointerRoute(self: *Self, x: f64, y: f64) PointerRoute {
    return self.pointerRouteExcluding(x, y, null);
}

fn dragPointerRoute(self: *Self, x: f64, y: f64) PointerRoute {
    return self.pointerRouteExcluding(x, y, self.xdg_toplevel_drag.attachedScene());
}

fn pointerRouteExcluding(
    self: *Self,
    x: f64,
    y: f64,
    excluded_window: ?Scene.Id,
) PointerRoute {
    const focus = self.pointerFocusExcluding(x, y, excluded_window);
    return .{
        .focus = focus,
        .root = if (focus) |value|
            self.subcompositor.rootSurface(value.surface_id)
        else if (self.session_lock.isLocked())
            null
        else
            self.borderRoot(x, y, excluded_window),
    };
}

fn borderRoot(self: *Self, x: f64, y: f64, excluded_window: ?Scene.Id) ?Surface.Id {
    const fullscreen = excludeScene(self.topFullscreenAtPoint(x, y), excluded_window);
    var nodes = self.scene.reverseNodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
            if (excluded_window) |excluded| {
                if (std.meta.eql(window_entry.id, excluded)) continue;
            }
            if (fullscreen) |fullscreen_id| {
                if (!std.meta.eql(window_entry.id, fullscreen_id)) continue;
            }
            const window = window_entry.window;
            if (!window.mapped) continue;
            const borders = window.borders orelse continue;
            const buffer = Surface.currentBuffer(self.compositor.surfaceStore(), window.surface_id) orelse continue;
            const content_size = if (window.content_geometry) |geometry|
                geometry.size
            else
                buffer.logical_size;
            const content = window_geometry.windowContentRect(window, content_size) orelse continue;
            var commands: [4]render.Command = undefined;
            const clip = if (window.clip_box) |box| box.translated(window.position.x, window.position.y) else null;
            for (window_geometry.makeBorderCommands(
                content,
                borders,
                window.effects.corner_radius,
                clip,
                &commands,
            )) |command| {
                if (window_geometry.pointInBorderCommand(x, y, command)) return window.surface_id;
            }
            if (fullscreen != null) return null;
        },
        else => {},
    };
    return null;
}

fn scenePointerFocus(
    self: *Self,
    x: f64,
    y: f64,
    excluded_window: ?Scene.Id,
) ?Seat.PointerFocus {
    var input_popups = self.input_method.reversePopupIterator();
    while (input_popups.next()) |popup| {
        if (self.hitTestSurface(
            popup.surface_id,
            .{ .x = popup.position.x, .y = popup.position.y },
            x,
            y,
        )) |focus| return focus;
    }
    if (self.hitTestLayerPopups(x, y)) |focus| return focus;
    if (self.hitTestLayer(.overlay, x, y)) |focus| return focus;
    const fullscreen = excludeScene(self.topFullscreenAtPoint(x, y), excluded_window);
    if (fullscreen == null) {
        if (self.hitTestLayer(.top, x, y)) |focus| return focus;
    }
    var nodes = self.scene.reverseNodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
            if (excluded_window) |excluded| {
                if (std.meta.eql(window_entry.id, excluded)) continue;
            }
            if (fullscreen) |fullscreen_id| {
                if (!std.meta.eql(window_entry.id, fullscreen_id)) continue;
                return self.hitTestWindow(window_entry.id, window_entry.window, x, y);
            }
            if (self.hitTestWindow(window_entry.id, window_entry.window, x, y)) |focus| return focus;
        },
        .shell_surface => |shell_entry| {
            const shell_surface = shell_entry.shell_surface;
            if (!shell_surface.mapped) continue;
            if (self.hitTestSurface(
                shell_surface.surface_id,
                shell_surface.position,
                x,
                y,
            )) |focus| return focus;
        },
    };
    if (fullscreen != null) return null;
    if (self.hitTestLayer(.bottom, x, y)) |focus| return focus;
    if (self.hitTestLayer(.background, x, y)) |focus| return focus;
    return null;
}

fn excludeScene(candidate: ?Scene.Id, excluded: ?Scene.Id) ?Scene.Id {
    const value = candidate orelse return null;
    if (excluded) |excluded_id| {
        if (std.meta.eql(value, excluded_id)) return null;
    }
    return value;
}

fn topFullscreenAtPoint(self: *Self, x: f64, y: f64) ?Scene.Id {
    var outputs = self.outputs.iterator();
    while (outputs.next()) |entry| {
        const output_rect = entry.output.logicalRect();
        if (window_geometry.pointInRect(x, y, output_rect)) {
            const fullscreen = self.topFullscreenForOutput(output_rect) orelse return null;
            return fullscreen.id;
        }
    }
    return null;
}

fn topFullscreenForOutput(self: *Self, output_rect: render.Rect) ?Scene.Iterator.Entry {
    var nodes = self.scene.reverseNodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
            const window = window_entry.window;
            if (!window.mapped or !window.fullscreen) continue;
            if (window.clip_box) |clip_box| {
                const global_clip = clip_box.translated(window.position.x, window.position.y);
                if (global_clip.intersection(output_rect) == null) continue;
            }
            return window_entry;
        },
        .shell_surface => {},
    };
    return null;
}

fn hitTestLayerPopups(self: *Self, x: f64, y: f64) ?Seat.PointerFocus {
    inline for (.{
        Scene.Layer.overlay,
        Scene.Layer.top,
        Scene.Layer.bottom,
        Scene.Layer.background,
    }) |layer| {
        var roots = self.scene.reverseLayerSurfaceIterator(layer);
        while (roots.next()) |root| {
            var popups = self.scene.reverseLayerPopupIterator(root.id);
            while (popups.next()) |entry| {
                if (!entry.popup.mapped) continue;
                const buffer = Surface.currentBuffer(
                    self.compositor.surfaceStore(),
                    entry.popup.surface_id,
                ) orelse continue;
                const geometry = entry.popup.content_geometry orelse Scene.ContentGeometry{
                    .size = buffer.logical_size,
                };
                if (self.hitTestSurface(entry.popup.surface_id, .{
                    .x = entry.position.x -| geometry.offset.x,
                    .y = entry.position.y -| geometry.offset.y,
                }, x, y)) |focus| return focus;
            }
        }
    }
    return null;
}

fn hitTestLayer(self: *Self, layer: Scene.Layer, x: f64, y: f64) ?Seat.PointerFocus {
    var surfaces = self.scene.reverseLayerSurfaceIterator(layer);
    while (surfaces.next()) |entry| {
        const layer_surface = entry.layer_surface;
        if (!layer_surface.mapped) continue;
        if (self.hitTestSurface(
            layer_surface.surface_id,
            layer_surface.position,
            x,
            y,
        )) |focus| return focus;
    }
    return null;
}

fn hitTestWindow(
    self: *Self,
    window_id: Scene.Id,
    window: *const Scene.Window,
    x: f64,
    y: f64,
) ?Seat.PointerFocus {
    if (!window.mapped) return null;
    var popups = self.scene.reversePopupIterator(window_id);
    while (popups.next()) |entry| {
        const popup = entry.popup;
        if (!popup.mapped) continue;
        const buffer = Surface.currentBuffer(
            self.compositor.surfaceStore(),
            popup.surface_id,
        ) orelse continue;
        const content_geometry = popup.content_geometry orelse Scene.ContentGeometry{
            .size = buffer.logical_size,
        };
        if (self.hitTestSurface(
            popup.surface_id,
            .{
                .x = entry.position.x -| content_geometry.offset.x,
                .y = entry.position.y -| content_geometry.offset.y,
            },
            x,
            y,
        )) |focus| return focus;
    }
    if (window.clip_box) |clip_box| {
        if (!window_geometry.pointInRect(x, y, clip_box.translated(window.position.x, window.position.y))) return null;
    }
    var above = self.scene.decorationIterator(window_id, .above);
    while (above.next()) |entry| if (entry.decoration.mapped) {
        if (self.hitTestSurface(entry.decoration.surface_id, .{
            .x = window.position.x +| entry.decoration.offset.x,
            .y = window.position.y +| entry.decoration.offset.y,
        }, x, y)) |focus| return focus;
    };
    const root_buffer = Surface.currentBuffer(
        self.compositor.surfaceStore(),
        window.surface_id,
    ) orelse return null;
    const content_geometry = window.content_geometry orelse Scene.ContentGeometry{
        .size = root_buffer.logical_size,
    };
    var test_content = true;
    if (window.content_clip_box) |clip_box| {
        const content_rect: render.Rect = .{
            .x = window.position.x,
            .y = window.position.y,
            .width = content_geometry.size.width,
            .height = content_geometry.size.height,
        };
        const visible = content_rect.intersection(
            clip_box.translated(window.position.x, window.position.y),
        );
        test_content = test_content and if (visible) |rect| window_geometry.pointInRect(x, y, rect) else false;
    }
    if (test_content and window.effects.corner_radius > 0) {
        const visible = window_geometry.windowContentRect(window, content_geometry.size) orelse return null;
        test_content = window_geometry.pointInRoundedRect(x, y, visible, window.effects.corner_radius);
    }
    if (test_content) if (self.hitTestSurface(
        window.surface_id,
        .{
            .x = window.position.x -| content_geometry.offset.x,
            .y = window.position.y -| content_geometry.offset.y,
        },
        x,
        y,
    )) |focus| return focus;
    var below = self.scene.decorationIterator(window_id, .below);
    while (below.next()) |entry| if (entry.decoration.mapped) {
        if (self.hitTestSurface(entry.decoration.surface_id, .{
            .x = window.position.x +| entry.decoration.offset.x,
            .y = window.position.y +| entry.decoration.offset.y,
        }, x, y)) |focus| return focus;
    };
    return null;
}

fn hitTestSurface(
    self: *Self,
    surface_id: Surface.Id,
    position: Scene.Position,
    x: f64,
    y: f64,
) ?Seat.PointerFocus {
    if (Surface.currentBuffer(self.compositor.surfaceStore(), surface_id) == null) return null;

    var stack = self.subcompositor.reverseStackIterator(surface_id);
    while (stack.next()) |entry| switch (entry) {
        .parent => {
            const surface_x = x - @as(f64, @floatFromInt(position.x));
            const surface_y = y - @as(f64, @floatFromInt(position.y));
            if (Surface.acceptsInput(
                self.compositor.surfaceStore(),
                surface_id,
                surface_x,
                surface_y,
            )) {
                return .{ .surface_id = surface_id, .x = surface_x, .y = surface_y };
            }
        },
        .child => |child| if (self.hitTestSurface(
            child.surface_id,
            .{
                .x = position.x +| child.position.x,
                .y = position.y +| child.position.y,
            },
            x,
            y,
        )) |focus| return focus,
    };
    return null;
}

fn captureConstraints(
    context: *anyopaque,
    target: ImageCopyCapture.Target,
) ?ImageCopyCapture.Constraints {
    const self: *Self = @ptrCast(@alignCast(context));
    return switch (target) {
        .source => |source| captureSourceConstraints(self, source),
        .cursor => |cursor| if (self.cursorCaptureState(cursor)) |state|
            .{ .size = state.size }
        else
            null,
    };
}

fn captureSourceConstraints(
    self: *Self,
    target: ImageCaptureSource.Target,
) ?ImageCopyCapture.Constraints {
    return switch (target) {
        .output => |output_id| output: {
            const render_output = self.renderOutputForProtocol(output_id) orelse return null;
            break :output .{ .size = render_output.backend.modeSize() };
        },
        .toplevel => |window_id| toplevel: {
            const bounds = self.toplevelCaptureBounds(window_id) orelse return null;
            break :toplevel .{ .size = .{ .width = bounds.width, .height = bounds.height } };
        },
    };
}

fn screencopyConstraints(context: *anyopaque, target: Screencopy.Target) ?render.Size {
    const self: *Self = @ptrCast(@alignCast(context));
    const render_output = self.renderOutputForProtocol(target.output) orelse return null;
    if (target.region) |region| {
        const physical = capture_geometry.scaledRegion(
            region,
            render_output.backend.renderScale(),
            render_output.backend.modeSize(),
        ) orelse return null;
        return .{ .width = physical.width, .height = physical.height };
    }
    return render_output.backend.modeSize();
}

fn scheduleImageCapture(
    context: *anyopaque,
    target: ImageCopyCapture.Target,
    wait_for_damage: bool,
) ?OutputLayout.Id {
    const self: *Self = @ptrCast(@alignCast(context));
    const output_id = switch (target) {
        .source => |source| switch (source) {
            .output => |output| output,
            .toplevel => (self.firstRenderOutput() orelse return null).protocol_id,
        },
        .cursor => return null,
    };
    return if (self.scheduleCaptureFrame(output_id, wait_for_damage)) output_id else null;
}

fn scheduleScreencopy(
    context: *anyopaque,
    target: Screencopy.Target,
    wait_for_damage: bool,
) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    return self.scheduleCaptureFrame(target.output, wait_for_damage);
}

fn scheduleCaptureFrame(
    self: *Self,
    output_id: OutputLayout.Id,
    wait_for_damage: bool,
) bool {
    const output = self.renderOutputForProtocol(output_id) orelse return false;
    if (!output.backend.powered()) return true;
    if (!wait_for_damage and output.damage.isEmpty()) {
        output.damage.setRectangle(0, 0, 1, 1);
    }
    if (!output.damage.isEmpty()) {
        output.requestFrame();
        self.scheduleRepaint(output);
    }
    return true;
}

fn xwaylandSurfaceAssociated(context: *anyopaque, serial: u64, surface_id: Surface.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwm_initialized) _ = self.xwm.associateSurface(serial, surface_id);
}

fn xwaylandSurfaceCommitted(
    context: *anyopaque,
    serial: u64,
    surface_id: Surface.Id,
    _: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.xwm_initialized) return;
    const window_id = self.xwm.windowForSerial(serial) orelse return;
    const window = self.xwayland_windows.get(window_id) orelse return;
    if (!std.meta.eql(window.surface_id, surface_id)) return;
    refreshXwaylandSceneWindow(self, window_id);
    updateXwaylandOverrideRedirectFocus(self, window_id);
    self.scene.surfaceCommitted(window.scene_id);
}

fn xwaylandSurfaceRemoved(context: *anyopaque, serial: u64, surface_id: Surface.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwm_initialized) self.xwm.removeSurfaceAssociation(serial, surface_id);
}

fn xwaylandReady(
    context: *anyopaque,
    display_name: []const u8,
    wm_fd: std.posix.fd_t,
) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    std.debug.assert(!self.xwm_initialized);
    self.xwm.init(
        self.allocator,
        self.display.getEventLoop(),
        wm_fd,
        &self.data_device,
        &self.primary_selection,
        .{
            .context = self,
            .failed = xwmFailed,
            .created = xwmWindowCreated,
            .destroyed = xwmWindowDestroyed,
            .mapped = xwmWindowMapped,
            .configured = xwmWindowConfigured,
            .metadata_changed = xwmWindowMetadataChanged,
            .fullscreen_requested = xwmWindowFullscreenRequested,
            .maximize_requested = xwmWindowMaximizeRequested,
            .minimize_requested = xwmWindowMinimizeRequested,
            .activation_requested = xwmWindowActivationRequested,
            .activation_changed = xwmWindowActivationChanged,
            .serial = xwmWindowSerial,
            .associated = xwmWindowAssociated,
            .dissociated = xwmWindowDissociated,
        },
    ) catch |err| {
        log.err("failed to initialize XWM: {t}", .{err});
        return false;
    };
    self.xwm_initialized = true;
    log.info("X11 clients may use DISPLAY={s}", .{display_name});
    return true;
}

fn xwaylandStopped(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwm_initialized) {
        self.xwm.deinit();
        self.xwm_initialized = false;
    }
    log.info("Xwayland stopped", .{});
}

fn xwaylandUnavailable(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwayland_display_listener) |listener|
        listener.unavailable(listener.context);
}

fn xwmFailed(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    std.debug.assert(self.xwm_initialized);
    self.xwm.deinit();
    self.xwm_initialized = false;
    self.xwayland_server.terminate();
}

fn xwmWindowCreated(_: *anyopaque, _: Xwm.WindowInfo) void {}

fn xwmWindowDestroyed(context: *anyopaque, window_id: Xwm.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized) self.window_manager.xwaylandWindowClosing(window_id);
}

fn xwmWindowMapped(context: *anyopaque, window_id: Xwm.WindowId, mapped: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowMapped(window_id, mapped);
    }
    if (self.foreign_toplevel_list_initialized) {
        const surface_id = if (self.xwayland_windows.get(window_id)) |window|
            window.surface_id
        else
            null;
        self.foreign_toplevel_list.xwaylandWindowMapped(
            window_id,
            mapped,
            surface_id,
        ) catch {
            log.err("failed to update X11 foreign-toplevel mapping", .{});
            return self.terminate();
        };
    }
    refreshXwaylandSceneWindow(self, window_id);
    applyXwaylandSceneStacking(self, window_id);
    updateXwaylandOverrideRedirectFocus(self, window_id);
}

fn xwmWindowConfigured(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    geometry: Xwm.Geometry,
    override_redirect: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const window = self.xwayland_windows.get(window_id) orelse return;
    configureXwaylandSceneWindow(self, window.scene_id, geometry);
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowConfigured(window_id, geometry, override_redirect);
    }
    if (self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowConfigured(
            window_id,
            override_redirect,
            window.surface_id,
        ) catch {
            log.err("failed to update X11 foreign-toplevel configuration", .{});
            return self.terminate();
        };
    }
    applyXwaylandSceneStacking(self, window_id);
    updateXwaylandOverrideRedirectFocus(self, window_id);
}

fn xwmWindowMetadataChanged(context: *anyopaque, window_id: Xwm.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const info = self.xwm.windowInfo(window_id) orelse return;
    log.debug("X11 window {d} metadata changed: type={s} app_id={?s} title={?s}", .{
        window_id,
        @tagName(info.window_type),
        info.app_id,
        info.title,
    });
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowMetadataChanged(window_id);
    }
    if (self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowMetadataChanged(window_id) catch {
            log.err("failed to update X11 foreign-toplevel metadata", .{});
            return self.terminate();
        };
    }
    applyXwaylandSceneStacking(self, window_id);
    updateXwaylandOverrideRedirectFocus(self, window_id);
}

fn xwmWindowFullscreenRequested(context: *anyopaque, window_id: Xwm.WindowId, fullscreen: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.foreign_toplevel_list_initialized) {
        const info = self.xwm.windowInfo(window_id) orelse return;
        if (info.fullscreen == fullscreen) {
            self.foreign_toplevel_list.xwaylandWindowStateChanged(window_id);
        }
    }
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowFullscreenRequested(window_id, fullscreen, null);
    }
}

fn xwmWindowMaximizeRequested(context: *anyopaque, window_id: Xwm.WindowId, maximized: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.foreign_toplevel_list_initialized) {
        const info = self.xwm.windowInfo(window_id) orelse return;
        if (info.maximized == maximized) {
            self.foreign_toplevel_list.xwaylandWindowStateChanged(window_id);
        }
    }
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowMaximizeRequested(window_id, maximized);
    }
}

fn xwmWindowMinimizeRequested(context: *anyopaque, window_id: Xwm.WindowId, minimized: bool) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.foreign_toplevel_list_initialized) {
        const info = self.xwm.windowInfo(window_id) orelse return;
        if (info.minimized == minimized) {
            self.foreign_toplevel_list.xwaylandWindowStateChanged(window_id);
        }
    }
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowMinimizeRequested(window_id, minimized);
    }
}

fn xwmWindowActivationRequested(context: *anyopaque, window_id: Xwm.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowActivationRequested(window_id, &self.seat);
    }
}

fn xwmWindowActivationChanged(context: *anyopaque, window_id: Xwm.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowStateChanged(window_id);
    }
}

fn xwmWindowSerial(context: *anyopaque, _: Xwm.WindowId, serial: u64) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const surface_id = self.xwayland_shell.surfaceForSerial(serial) orelse return;
    _ = self.xwm.associateSurface(serial, surface_id);
}

fn xwmWindowAssociated(context: *anyopaque, window_id: Xwm.WindowId, surface_id: Surface.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    const info = self.xwm.windowInfo(window_id) orelse return;
    const scene_id = self.scene.addWindow(surface_id) catch {
        log.err("failed to add X11 window {d} to the scene", .{window_id});
        self.terminate();
        return;
    };
    self.xwayland_windows.put(self.allocator, window_id, .{
        .scene_id = scene_id,
        .surface_id = surface_id,
    }) catch {
        self.scene.removeWindow(scene_id);
        log.err("failed to track X11 window {d}", .{window_id});
        self.terminate();
        return;
    };
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowAssociated(
            window_id,
            scene_id,
            surface_id,
        ) catch {
            _ = self.xwayland_windows.remove(window_id);
            self.scene.removeWindow(scene_id);
            log.err("failed to expose X11 window {d} to the window manager", .{window_id});
            self.terminate();
            return;
        };
    }
    if (self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowAssociated(window_id, surface_id) catch {
            if (self.window_manager_initialized) {
                self.window_manager.xwaylandWindowDissociated(window_id);
            }
            _ = self.xwayland_windows.remove(window_id);
            self.scene.removeWindow(scene_id);
            log.err("failed to expose X11 window {d} through foreign-toplevel", .{window_id});
            self.terminate();
            return;
        };
    }
    configureXwaylandSceneWindow(self, scene_id, info.geometry);
    refreshXwaylandSceneWindow(self, window_id);
    applyXwaylandSceneStacking(self, window_id);
    updateXwaylandOverrideRedirectFocus(self, window_id);
}

fn xwmWindowDissociated(context: *anyopaque, window_id: Xwm.WindowId, _: Surface.Id) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized and self.xwayland_windows.contains(window_id)) {
        self.window_manager.xwaylandWindowDissociated(window_id);
    }
    if (self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowDissociated(window_id);
    }
    removeXwaylandWindow(self, window_id);
}

fn configureXwaylandSceneWindow(
    self: *Self,
    scene_id: Scene.Id,
    geometry: Xwm.Geometry,
) void {
    self.scene.setPosition(scene_id, .{ .x = geometry.x, .y = geometry.y });
    self.scene.setContentGeometry(scene_id, .{
        .size = .{ .width = geometry.width, .height = geometry.height },
    });
}

fn refreshXwaylandSceneWindow(self: *Self, window_id: Xwm.WindowId) void {
    const window = self.xwayland_windows.get(window_id) orelse return;
    const info = self.xwm.windowInfo(window_id) orelse return;
    const has_buffer = Surface.currentBuffer(
        self.compositor.surfaceStore(),
        window.surface_id,
    ) != null;
    const displayed = !self.window_manager_initialized or
        self.window_manager.xwaylandWindowDisplayed(window_id);
    self.scene.setMapped(window.scene_id, info.mapped and has_buffer and displayed);
}

fn applyXwaylandSceneStacking(self: *Self, window_id: Xwm.WindowId) void {
    const window = self.xwayland_windows.get(window_id) orelse return;
    const info = self.xwm.windowInfo(window_id) orelse return;
    if (info.window_type == .desktop) {
        self.scene.placeBottom(window.scene_id);
    } else if (!info.participatesInWindowManagement()) {
        self.scene.placeTop(window.scene_id);
    } else if (info.parent) |parent_id| {
        if (self.xwayland_windows.get(parent_id)) |parent| {
            self.scene.placeAbove(window.scene_id, parent.scene_id);
        }
    }
    syncXwaylandClientStacking(self);
}

fn syncXwaylandClientStacking(self: *Self) void {
    if (!self.xwm_initialized) return;
    self.xwayland_client_stack.clearRetainingCapacity();
    var scene_windows = self.scene.iterator();
    while (scene_windows.next()) |scene_window| {
        var xwayland_windows = self.xwayland_windows.iterator();
        while (xwayland_windows.next()) |entry| {
            if (!std.meta.eql(entry.value_ptr.scene_id, scene_window.id)) continue;
            const info = self.xwm.windowInfo(entry.key_ptr.*) orelse break;
            if (info.mapped and !info.override_redirect) {
                self.xwayland_client_stack.append(
                    self.allocator,
                    entry.key_ptr.*,
                ) catch return self.terminate();
            }
            break;
        }
    }
    self.xwm.setClientStacking(self.xwayland_client_stack.items) catch {
        log.err("failed to publish X11 client stacking", .{});
        self.terminate();
    };
}

fn updateXwaylandOverrideRedirectFocus(self: *Self, window_id: Xwm.WindowId) void {
    const window = self.xwayland_windows.get(window_id) orelse return;
    const info = self.xwm.windowInfo(window_id) orelse return;
    if (info.mapped and info.override_redirect and info.override_redirect_wants_focus and
        self.scene.surfaceMapped(window.surface_id))
    {
        if (self.xwayland_override_redirect_focus) |current| {
            if (std.meta.eql(current, window.surface_id)) return;
        }
        self.xwayland_override_redirect_focus = window.surface_id;
        refreshKeyboardFocus(self);
        return;
    }
    const current = self.xwayland_override_redirect_focus orelse return;
    if (!std.meta.eql(current, window.surface_id)) return;
    var replacement: ?Surface.Id = null;
    if (info.parent) |parent_id| {
        if (self.xwayland_windows.get(parent_id)) |parent| {
            if (self.xwm.windowInfo(parent_id)) |parent_info| {
                if (parent_info.mapped and parent_info.override_redirect and
                    parent_info.override_redirect_wants_focus and
                    self.scene.surfaceMapped(parent.surface_id))
                {
                    replacement = parent.surface_id;
                }
            }
        }
    }
    self.xwayland_override_redirect_focus = replacement;
    refreshKeyboardFocus(self);
}

fn xwaylandWindowInfo(context: *anyopaque, window_id: Xwm.WindowId) ?Xwm.WindowInfo {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.xwm_initialized) return null;
    return self.xwm.windowInfo(window_id);
}

fn resizeXwaylandWindow(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    width: u16,
    height: u16,
) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.xwm_initialized) return false;
    self.xwm.resizeWindow(window_id, width, height) catch |err| {
        log.warn("failed to resize X11 window {d}: {t}", .{ window_id, err });
        return false;
    };
    return true;
}

fn moveXwaylandWindow(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    x: i16,
    y: i16,
) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.xwm_initialized) return false;
    self.xwm.moveWindow(window_id, x, y) catch |err| {
        log.warn("failed to move X11 window {d}: {t}", .{ window_id, err });
        return false;
    };
    return true;
}

fn setXwaylandWindowFullscreen(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    fullscreen: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.xwm_initialized) return;
    const changed = self.xwm.setFullscreen(window_id, fullscreen) catch |err| {
        log.warn("failed to set X11 window {d} fullscreen state: {t}", .{ window_id, err });
        return;
    };
    if (changed and self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowStateChanged(window_id);
    }
}

fn setXwaylandWindowMaximized(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    maximized: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.xwm_initialized) return;
    const changed = self.xwm.setMaximized(window_id, maximized) catch |err| {
        log.warn("failed to set X11 window {d} maximized state: {t}", .{ window_id, err });
        return;
    };
    if (changed and self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowStateChanged(window_id);
    }
}

fn setXwaylandWindowMinimized(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    minimized: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (!self.xwm_initialized) return;
    const changed = self.xwm.setMinimized(window_id, minimized) catch |err| {
        log.warn("failed to set X11 window {d} minimized state: {t}", .{ window_id, err });
        return;
    };
    if (changed and self.foreign_toplevel_list_initialized) {
        self.foreign_toplevel_list.xwaylandWindowStateChanged(window_id);
    }
}

fn requestXwaylandWindowFullscreen(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    fullscreen: bool,
    preferred_output: ?OutputLayout.Id,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowFullscreenRequested(
            window_id,
            fullscreen,
            preferred_output,
        );
    }
}

fn requestXwaylandWindowActivation(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    seat: *Seat,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowActivationRequested(window_id, seat);
    }
}

fn requestXwaylandWindowMaximized(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    maximized: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowMaximizeRequested(window_id, maximized);
    }
}

fn requestXwaylandWindowMinimized(
    context: *anyopaque,
    window_id: Xwm.WindowId,
    minimized: bool,
) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.window_manager_initialized) {
        self.window_manager.xwaylandWindowMinimizeRequested(window_id, minimized);
    }
}

fn closeXwaylandWindow(context: *anyopaque, window_id: Xwm.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwm_initialized) self.xwm.closeWindow(window_id);
}

fn refreshXwaylandScene(context: *anyopaque, window_id: Xwm.WindowId) void {
    const self: *Self = @ptrCast(@alignCast(context));
    if (self.xwm_initialized) refreshXwaylandSceneWindow(self, window_id);
}

fn xwaylandStackingChanged(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    syncXwaylandClientStacking(self);
}

fn removeXwaylandWindow(self: *Self, window_id: Xwm.WindowId) void {
    const removed = self.xwayland_windows.fetchRemove(window_id) orelse return;
    self.scene.removeWindow(removed.value.scene_id);
    syncXwaylandClientStacking(self);
    if (self.xwayland_override_redirect_focus) |current| {
        if (std.meta.eql(current, removed.value.surface_id)) {
            self.xwayland_override_redirect_focus = null;
            refreshKeyboardFocus(self);
        }
    }
}

fn xwaylandWindowForSurface(self: *Self, surface_id: Surface.Id) ?Xwm.WindowId {
    var windows = self.xwayland_windows.iterator();
    while (windows.next()) |entry| {
        if (std.meta.eql(entry.value_ptr.surface_id, surface_id)) return entry.key_ptr.*;
    }
    return null;
}

fn syncXwaylandFocus(self: *Self, surface_id: ?Surface.Id) void {
    if (!self.xwm_initialized) return;
    const target: ?Xwm.WindowId = if (surface_id) |surface| target: {
        var windows = self.xwayland_windows.iterator();
        while (windows.next()) |entry| {
            if (std.meta.eql(entry.value_ptr.surface_id, surface)) break :target entry.key_ptr.*;
        }
        break :target null;
    } else null;
    self.xwm.focusWindow(target) catch {
        log.err("failed to update X11 input focus", .{});
        self.terminate();
    };
}

fn captureImage(
    context: *anyopaque,
    target: ImageCopyCapture.Target,
    paint_cursors: bool,
    pixel_buffer: render.PixelBuffer,
) ImageCopyCapture.CaptureError!ImageCopyCapture.CaptureResult {
    const self: *Self = @ptrCast(@alignCast(context));
    const completion_fd = switch (target) {
        .source => |source| switch (source) {
            .output => |output_id| self.captureOutput(
                output_id,
                paint_cursors,
                pixel_buffer,
            ) catch return error.Failed,
            .toplevel => |window_id| toplevel: {
                if (self.session_lock.isLocked()) return error.Failed;
                break :toplevel self.captureToplevel(window_id, pixel_buffer) catch |err| switch (err) {
                    error.Stopped => return error.Stopped,
                    else => return error.Failed,
                };
            },
        },
        .cursor => |cursor| self.captureCursor(cursor, pixel_buffer) catch return error.Failed,
    };
    return .{
        .timestamp = presentation.Info.now(self.io).timestamp,
        .completion_fd = completion_fd,
    };
}

fn captureScreencopy(
    context: *anyopaque,
    target: Screencopy.Target,
    overlay_cursor: bool,
    pixel_buffer: render.PixelBuffer,
) Screencopy.CaptureError!Screencopy.CaptureResult {
    const self: *Self = @ptrCast(@alignCast(context));
    const completion_fd = self.captureOutputRegion(
        target.output,
        target.region,
        overlay_cursor,
        pixel_buffer,
    ) catch return error.Failed;
    return .{
        .timestamp = presentation.Info.now(self.io).timestamp,
        .completion_fd = completion_fd,
    };
}

fn captureImageDmabuf(
    context: *anyopaque,
    target: ImageCopyCapture.Target,
    paint_cursors: bool,
    buffer: *LinuxDmabuf.Buffer,
) ImageCopyCapture.CaptureError!presentation.Timestamp {
    const self: *Self = @ptrCast(@alignCast(context));
    const access = self.renderer.dmabufAccess() orelse return error.Failed;
    const capture_target = buffer.captureTarget(access) catch return error.Failed;
    const completion = switch (target) {
        .source => |source| switch (source) {
            .output => |output_id| self.captureFullOutputTarget(
                output_id,
                paint_cursors,
                .{ .dmabuf = capture_target },
            ) catch return error.Failed,
            .toplevel => |window_id| toplevel: {
                if (self.session_lock.isLocked()) return error.Failed;
                break :toplevel self.captureToplevelTarget(
                    window_id,
                    .{ .dmabuf = capture_target },
                ) catch |err| switch (err) {
                    error.Stopped => return error.Stopped,
                    else => return error.Failed,
                };
            },
        },
        .cursor => |cursor| self.captureCursorTarget(
            cursor,
            .{ .dmabuf = capture_target },
        ) catch return error.Failed,
    };
    finishDmabufCapture(buffer, completion) catch return error.Failed;
    return presentation.Info.now(self.io).timestamp;
}

fn captureScreencopyDmabuf(
    context: *anyopaque,
    target: Screencopy.Target,
    overlay_cursor: bool,
    buffer: *LinuxDmabuf.Buffer,
) Screencopy.CaptureError!presentation.Timestamp {
    const self: *Self = @ptrCast(@alignCast(context));
    const access = self.renderer.dmabufAccess() orelse return error.Failed;
    const capture_target = buffer.captureTarget(access) catch return error.Failed;
    const completion = self.captureOutputTarget(
        target.output,
        target.region,
        overlay_cursor,
        .{ .dmabuf = capture_target },
    ) catch return error.Failed;
    finishDmabufCapture(buffer, completion) catch return error.Failed;
    return presentation.Info.now(self.io).timestamp;
}

fn finishDmabufCapture(
    buffer: *LinuxDmabuf.Buffer,
    completion: Renderer.FrameCompletion,
) error{CaptureSyncFailed}!void {
    const sync_file_fd = completion.sync_file_fd orelse return;
    defer _ = std.c.close(sync_file_fd);
    if (buffer.importWriteFence(sync_file_fd)) return;
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = sync_file_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    if ((std.posix.poll(&poll_fds, -1) catch return error.CaptureSyncFailed) != 1 or
        poll_fds[0].revents & std.posix.POLL.IN == 0 or
        poll_fds[0].revents &
            (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0)
    {
        return error.CaptureSyncFailed;
    }
}

fn completeCaptureReadback(
    context: *anyopaque,
    source: render.PixelBuffer,
    destination: ?render.PixelBuffer,
) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    self.renderer.completeFrameReadback(source, destination) catch |err| {
        log.err("screen capture readback completion failed: {t}", .{err});
        return false;
    };
    return destination != null;
}

const CursorCaptureState = struct {
    cursor: Seat.CursorInfo,
    bounds: render.Rect,
    scale: render.Scale,
    size: render.Size,
    position: render.Position,
    hotspot: render.Position,
    entered: bool,
};

fn captureCursorInfo(
    context: *anyopaque,
    target: ImageCopyCapture.CursorTarget,
) ?ImageCopyCapture.CursorInfo {
    const self: *Self = @ptrCast(@alignCast(context));
    const state = self.cursorCaptureState(target) orelse return null;
    return .{
        .entered = state.entered,
        .position = state.position,
        .hotspot = state.hotspot,
    };
}

fn cursorCaptureState(
    self: *Self,
    target: ImageCopyCapture.CursorTarget,
) ?CursorCaptureState {
    const source_bounds, const scale, const cursor = switch (target.source) {
        .output => |output_id| output: {
            const render_output = self.renderOutputForProtocol(output_id) orelse return null;
            const output = self.outputs.get(output_id) orelse return null;
            const cursor = self.seatCursorInfo(
                target.seat,
                self.session_lock.isLocked(),
            ) orelse return null;
            break :output .{
                output.logicalRect(),
                render_output.backend.renderScale(),
                cursor,
            };
        },
        .toplevel => |window_id| toplevel: {
            if (self.session_lock.isLocked()) return null;
            const bounds = self.toplevelCaptureBounds(window_id) orelse return null;
            const cursor = self.seatCursorInfo(target.seat, false) orelse return null;
            break :toplevel .{ bounds, render.Scale{}, cursor };
        },
    };
    const pointer = target.seat.pointerPosition() orelse return null;
    const pointer_x = capture_geometry.floorToI32(pointer.x);
    const pointer_y = capture_geometry.floorToI32(pointer.y);
    const bounds = self.cursorBounds(cursor) orelse return null;
    const size = scale.apply(.{ .width = bounds.width, .height = bounds.height }) catch
        return null;
    if (size.width == 0 or size.height == 0) return null;
    const position: render.Position = .{
        .x = capture_geometry.scaleCoordinate(@as(i64, pointer_x) - source_bounds.x, scale),
        .y = capture_geometry.scaleCoordinate(@as(i64, pointer_y) - source_bounds.y, scale),
    };
    const image_origin: render.Position = .{
        .x = capture_geometry.scaleCoordinate(@as(i64, bounds.x) - source_bounds.x, scale),
        .y = capture_geometry.scaleCoordinate(@as(i64, bounds.y) - source_bounds.y, scale),
    };
    return .{
        .cursor = cursor,
        .bounds = bounds,
        .scale = scale,
        .size = size,
        .position = position,
        .hotspot = .{
            .x = position.x -| image_origin.x,
            .y = position.y -| image_origin.y,
        },
        .entered = bounds.intersection(source_bounds) != null,
    };
}

fn captureCursor(
    self: *Self,
    target: ImageCopyCapture.CursorTarget,
    pixel_buffer: render.PixelBuffer,
) Renderer.Error!?std.posix.fd_t {
    const completion = try self.captureCursorTarget(target, .{ .pixels = pixel_buffer });
    return completion.sync_file_fd;
}

fn captureCursorTarget(
    self: *Self,
    target: ImageCopyCapture.CursorTarget,
    render_target: render.Target,
) Renderer.Error!Renderer.FrameCompletion {
    const state = self.cursorCaptureState(target) orelse return error.InvalidTarget;
    if (!std.meta.eql(render_target.size(), state.size)) return error.InvalidTarget;
    const render_output = switch (target.source) {
        .output => |output_id| self.renderOutputForProtocol(output_id),
        .toplevel => self.firstRenderOutput(),
    } orelse return error.InvalidTarget;
    const output = self.outputs.get(render_output.protocol_id) orelse return error.InvalidTarget;
    try self.renderer.beginFrame(
        render_target,
        state.scale,
        .{ .x = state.bounds.x, .y = state.bounds.y },
        null,
        .{},
    );
    var renderer_frame_active = true;
    errdefer if (renderer_frame_active) self.renderer.cancelFrame();
    var next_backdrop_capture_id: u32 = 1;
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .visible_rect = state.bounds,
        .track_visibility = false,
        .next_backdrop_capture_id = &next_backdrop_capture_id,
    };
    const clear_command = [_]render.Command{.{ .clear = render.Color.rgba(0, 0, 0, 0) }};
    try self.renderCommands(&frame, &clear_command);
    try self.renderCursor(&frame, state.cursor);
    renderer_frame_active = false;
    return self.finishCaptureTarget(render_target);
}

fn finishCaptureTarget(
    self: *Self,
    target: render.Target,
) Renderer.Error!Renderer.FrameCompletion {
    return switch (target) {
        .pixels => self.renderer.finishFrameReadback(),
        .dmabuf => self.renderer.finishFrameScanout(null),
        .offscreen => error.InvalidTarget,
    };
}

test "output capture uses pixel dimensions at fractional scale" {
    const server = try Self.createWithVirtualOutput(
        std.testing.allocator,
        std.testing.io,
        .cpu,
        .headless,
        null,
        .{
            .size = .{ .width = 6, .height = 3 },
            .scale = .{ .numerator = 180 },
        },
    );
    defer server.destroy();
    const output = server.primaryRenderOutput();

    try std.testing.expectEqual(
        render.Size{ .width = 6, .height = 3 },
        captureSourceConstraints(server, .{ .output = output.protocol_id }).?.size,
    );
    try std.testing.expectEqual(
        render.Size{ .width = 6, .height = 3 },
        screencopyConstraints(server, .{ .output = output.protocol_id }).?,
    );

    var pixels: [18]u32 = undefined;
    _ = try server.captureOutput(output.protocol_id, false, .{
        .size = .{ .width = 6, .height = 3 },
        .stride_pixels = 6,
        .pixels = &pixels,
    });
    const background = renderColor(server.palette.desktop_background).argb8888();
    for (pixels) |pixel| try std.testing.expectEqual(background, pixel);
}

test "promoted overlay damage remains stale for the next frame" {
    var damage = Region.init();
    defer damage.deinit();
    preservePromotedDamage(
        &damage,
        .{ .x = 10, .y = 20, .width = 30, .height = 40 },
        .{ .width = 100, .height = 100 },
    );
    try std.testing.expect(damage.coversRectangle(10, 20, 30, 40));
}

fn captureOutput(
    self: *Self,
    output_id: OutputLayout.Id,
    paint_cursors: bool,
    pixel_buffer: render.PixelBuffer,
) Renderer.Error!?std.posix.fd_t {
    return self.captureOutputRegion(output_id, null, paint_cursors, pixel_buffer);
}

fn captureOutputRegion(
    self: *Self,
    output_id: OutputLayout.Id,
    local_region: ?render.Rect,
    paint_cursors: bool,
    pixel_buffer: render.PixelBuffer,
) Renderer.Error!?std.posix.fd_t {
    const completion = try self.captureOutputTarget(
        output_id,
        local_region,
        paint_cursors,
        .{ .pixels = pixel_buffer },
    );
    return completion.sync_file_fd;
}

fn captureFullOutputTarget(
    self: *Self,
    output_id: OutputLayout.Id,
    paint_cursors: bool,
    render_target: render.Target,
) Renderer.Error!Renderer.FrameCompletion {
    return self.captureOutputTarget(output_id, null, paint_cursors, render_target);
}

fn captureOutputTarget(
    self: *Self,
    output_id: OutputLayout.Id,
    local_region: ?render.Rect,
    paint_cursors: bool,
    render_target: render.Target,
) Renderer.Error!Renderer.FrameCompletion {
    const render_output = self.renderOutputForProtocol(output_id) orelse
        return error.InvalidTarget;
    const output = self.outputs.get(output_id) orelse return error.InvalidTarget;
    const scale = render_output.backend.renderScale();
    const output_size = render_output.backend.modeSize();
    const source_region = if (local_region) |region|
        capture_geometry.scaledRegion(region, scale, output_size) orelse
            return error.InvalidTarget
    else
        null;
    const expected_size = if (source_region) |region|
        render.Size{ .width = region.width, .height = region.height }
    else
        output_size;
    if (!std.meta.eql(render_target.size(), expected_size)) return error.InvalidTarget;
    if (self.composed_capture_source) |source| {
        if (std.meta.eql(source.output, output_id) and
            self.composedCaptureMatchesCursors(
                source,
                output.logicalRect(),
                local_region,
                paint_cursors,
            ))
        {
            const copied = self.renderer.copyComposedFrame(
                source.target,
                source_region,
                render_target,
                .{},
            ) catch |err| copied: {
                log.warn("composed screen capture copy failed; rerendering: {t}", .{err});
                break :copied null;
            };
            if (copied) |completion| return completion;
        }
    }
    const output_rect = output.logicalRect();
    const visible_rect = capture_geometry.logicalRect(output_rect, local_region);
    try self.renderer.beginFrame(
        render_target,
        scale,
        .{ .x = visible_rect.x, .y = visible_rect.y },
        null,
        .{},
    );
    var renderer_frame_active = true;
    errdefer if (renderer_frame_active) self.renderer.cancelFrame();
    var next_backdrop_capture_id: u32 = 1;
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .visible_rect = visible_rect,
        .track_visibility = false,
        .next_backdrop_capture_id = &next_backdrop_capture_id,
    };
    const clear_command = [_]render.Command{.{
        .clear = outputClearColor(self.palette, self.session_lock.isLocked()),
    }};
    try self.renderCommands(&frame, &clear_command);
    if (self.session_lock.isLocked()) {
        try self.renderSessionLockContents(&frame, paint_cursors, paint_cursors);
    } else {
        _ = try self.renderDesktopContents(&frame, paint_cursors, paint_cursors);
    }
    renderer_frame_active = false;
    return self.finishCaptureTarget(render_target);
}

fn composedCaptureMatchesCursors(
    self: *Self,
    source: ComposedCaptureSource,
    output_rect: render.Rect,
    local_region: ?render.Rect,
    paint_cursors: bool,
) bool {
    const capture_rect = capture_geometry.logicalRect(output_rect, local_region);
    const locked = self.session_lock.isLocked();
    if (source.primary_cursor_painted != paint_cursors) {
        if (self.seatCursorInfo(&self.seat, locked)) |cursor| {
            if (capture_geometry.cursorMismatchAffects(
                source.primary_cursor_painted,
                paint_cursors,
                self.cursorBounds(cursor),
                capture_rect,
            )) return false;
        }
    }
    if (source.tablet_cursors_painted != paint_cursors) {
        var cursors = self.tablet.cursorIterator();
        while (cursors.next()) |info| {
            if (!self.tabletCursorVisible(info.focus_surface, locked)) continue;
            if (capture_geometry.cursorMismatchAffects(
                source.tablet_cursors_painted,
                paint_cursors,
                self.cursorBounds(info.cursor),
                capture_rect,
            )) return false;
        }
    }
    return true;
}

const ToplevelCaptureError = Renderer.Error || error{Stopped};

fn captureToplevel(
    self: *Self,
    window_id: XdgShell.WindowId,
    pixel_buffer: render.PixelBuffer,
) ToplevelCaptureError!?std.posix.fd_t {
    const completion = try self.captureToplevelTarget(window_id, .{ .pixels = pixel_buffer });
    return completion.sync_file_fd;
}

fn captureToplevelTarget(
    self: *Self,
    window_id: XdgShell.WindowId,
    render_target: render.Target,
) ToplevelCaptureError!Renderer.FrameCompletion {
    const info = self.xdg_shell.windowInfo(window_id) orelse return error.Stopped;
    if (!info.mapped) return error.Stopped;
    const surface_id = self.xdg_shell.windowSurface(window_id) orelse return error.Stopped;
    const position = self.scene.surfacePosition(surface_id) orelse return error.Stopped;
    const bounds = self.toplevelCaptureBounds(window_id) orelse return error.Stopped;
    if (!std.meta.eql(render_target.size(), render.Size{
        .width = bounds.width,
        .height = bounds.height,
    })) return error.InvalidTarget;
    const render_output = self.firstRenderOutput() orelse return error.InvalidTarget;
    const output = self.outputs.get(render_output.protocol_id) orelse return error.InvalidTarget;
    try self.renderer.beginFrame(
        render_target,
        .{},
        .{ .x = bounds.x, .y = bounds.y },
        null,
        .{},
    );
    var renderer_frame_active = true;
    errdefer if (renderer_frame_active) self.renderer.cancelFrame();
    var next_backdrop_capture_id: u32 = 1;
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .visible_rect = bounds,
        .track_visibility = false,
        .next_backdrop_capture_id = &next_backdrop_capture_id,
    };
    const clear_command = [_]render.Command{.{ .clear = render.Color.rgba(0, 0, 0, 0) }};
    try self.renderCommands(&frame, &clear_command);
    try self.renderSurfaceTree(
        &frame,
        surface_id,
        position.x,
        position.y,
        null,
        null,
    );
    renderer_frame_active = false;
    return self.finishCaptureTarget(render_target);
}

fn renderOutputForProtocol(self: *Self, output_id: OutputLayout.Id) ?*RenderOutput {
    var outputs = self.render_outputs.iterator();
    while (outputs.next()) |entry| {
        const render_output = entry.value.*;
        if (std.meta.eql(render_output.protocol_id, output_id)) return render_output;
    }
    return null;
}

fn firstRenderOutput(self: *Self) ?*RenderOutput {
    var outputs = self.render_outputs.iterator();
    const entry = outputs.next() orelse return null;
    return entry.value.*;
}

fn toplevelCaptureBounds(self: *Self, window_id: XdgShell.WindowId) ?render.Rect {
    const info = self.xdg_shell.windowInfo(window_id) orelse return null;
    if (!info.mapped) return null;
    const surface_id = self.xdg_shell.windowSurface(window_id) orelse return null;
    const position = self.scene.surfacePosition(surface_id) orelse return null;
    var bounds: ?render.Rect = null;
    self.addSurfaceTreeBounds(surface_id, position.x, position.y, &bounds) catch return null;
    return bounds;
}

fn addSurfaceTreeBounds(
    self: *Self,
    surface_id: Surface.Id,
    x: i32,
    y: i32,
    bounds: *?render.Rect,
) error{Overflow}!void {
    if (Surface.currentBuffer(self.compositor.surfaceStore(), surface_id) == null) return;
    var stack = self.subcompositor.stackIterator(surface_id);
    while (stack.next()) |entry| switch (entry) {
        .parent => {
            const buffer = Surface.currentBuffer(
                self.compositor.surfaceStore(),
                surface_id,
            ) orelse continue;
            const rect: render.Rect = .{
                .x = x,
                .y = y,
                .width = buffer.logical_size.width,
                .height = buffer.logical_size.height,
            };
            bounds.* = if (bounds.*) |current|
                try capture_geometry.unionBounds(current, rect)
            else
                rect;
        },
        .child => |child| try self.addSurfaceTreeBounds(
            child.surface_id,
            x +| child.position.x,
            y +| child.position.y,
            bounds,
        ),
    };
}

fn handleRenderTimer(output_context: *RenderOutput) c_int {
    handleScheduledRender(output_context);
    return 0;
}

fn handleFrameCallbackTimer(output_context: *RenderOutput) c_int {
    output_context.frame_callback_scheduled = false;
    if (!output_context.backend.powered()) return 0;

    const now = nowNanoseconds(output_context.server.io);
    const timestamp = presentation.Timestamp.fromNanoseconds(now);
    const output = output_context.server.outputs.get(output_context.protocol_id).?;
    if (output.sendCallbackOnlyFrameCallbacks(timestamp.milliseconds())) {
        log.debug("completed callback-only frame callbacks for {s}", .{output.name()});
    }
    return 0;
}

fn handleRenderIdle(output_context: *RenderOutput) void {
    std.debug.assert(output_context.repaint_idle != null);
    output_context.repaint_idle = null;
    handleScheduledRender(output_context);
}

fn handleScheduledRender(output_context: *RenderOutput) void {
    const self = output_context.server;
    output_context.render_scheduled = false;
    if (!output_context.repaint_needed or !output_context.backend.ready()) return;
    std.debug.assert(!output_context.damage.isEmpty());
    output_context.repaint_needed = false;
    self.renderFrame(output_context) catch |err| {
        log.err("output frame failed: {t}", .{err});
        self.terminate();
    };
    self.scheduleRepaint(output_context);
}

fn expandBackdropBlurDamage(
    self: *Self,
    render_output: *const RenderOutput,
    output: *const Output,
    damage: *Region,
    source_root: ?Surface.Id,
) (Region.Error || error{UnresolvedBlurSource})!void {
    const surface_blur = Scene.background_blur;
    var changed = true;
    while (changed) {
        changed = false;
        const surfaces = self.compositor.surfaceStore();
        var surface_iterator = surfaces.iterator();
        while (surface_iterator.next()) |surface_entry| {
            const region = Surface.currentBlurRegion(surfaces, surface_entry.id) orelse continue;
            const buffer = Surface.currentBuffer(surfaces, surface_entry.id) orelse continue;
            if (surfaceFullyOpaque(surfaces, surface_entry.id, buffer)) continue;
            const root = self.subcompositor.rootSurface(surface_entry.id);
            if (source_root) |source| {
                // A tree is painted after its backdrop capture, so its own commits
                // cannot change that capture. A lower top-level node cannot depend
                // on a commit above it; other surface categories remain conservative.
                if (std.meta.eql(root, source)) continue;
                if (self.scene.surfaceNodeAbove(root, source)) |above| {
                    if (!above) continue;
                }
            }
            if (!self.scene.surfaceMapped(root)) {
                // Blur roots rendered outside the scene (input method popups,
                // drag icons, session lock surfaces) cannot be resolved here,
                // so callers must repaint the whole output.
                if (!self.scene.surfaceTracked(root)) return error.UnresolvedBlurSource;
                continue;
            }
            const root_position = self.scene.surfacePosition(root) orelse
                return error.UnresolvedBlurSource;
            const offset = self.subcompositor.surfaceOffset(surface_entry.id);
            var rectangles = region.rectangleIterator();
            while (rectangles.next()) |rectangle| {
                const local = surfaceEffectRect(rectangle, buffer.logical_size) orelse continue;
                const blur = backdrop_blur_damage.areaForOutput(
                    local.translated(
                        root_position.x +| offset.x,
                        root_position.y +| offset.y,
                    ),
                    output.logicalRect(),
                    render_output.backend.renderScale(),
                    render_output.backend.modeSize(),
                    surface_blur.radius,
                    surface_blur.downsample_level,
                ) orelse continue;
                changed = try backdrop_blur_damage.propagate(
                    damage,
                    blur,
                    render_output.backend.modeSize(),
                ) or changed;
            }
        }
    }
}

fn renderFrame(self: *Self, render_output: *RenderOutput) Renderer.Error!void {
    // Frame production starts here: transition processing below may render
    // window snapshots, so the repaint-delay budget must include it.
    const render_start_nanoseconds = nowNanoseconds(self.io);
    self.animation_now = render_start_nanoseconds;
    if (self.reduced_motion or self.session_lock.isLocked() or
        self.xdg_shell.hasPopupGrab() or self.window_manager.directManipulationActive())
    {
        finishAllWindowTransitions(self);
        finishAllWorkspaceTransitions(self);
    } else {
        var transition_index: usize = 0;
        while (transition_index < self.window_transitions.items.len) {
            const transition = self.window_transitions.items[transition_index];
            if (windowTransitionHasPopup(self, transition.scene_id)) {
                destroyWindowTransition(self, transition_index);
                continue;
            }
            switch (transition.phase) {
                .waiting => {
                    if (transition.kind == .disappearance) {
                        const start = if (self.windowReflowIndex(
                            transition.output_id,
                            transition.old_rect,
                            .absorbed,
                        )) |reflow_index| start: {
                            const reflow = self.window_transitions.items[reflow_index];
                            if (reflow.phase == .waiting) {
                                transition_index += 1;
                                continue;
                            }
                            break :start reflow.start;
                        } else self.animation_now;
                        self.window_transitions.items[transition_index].phase = .animating;
                        self.window_transitions.items[transition_index].start = start;
                    }
                    transition_index += 1;
                },
                .target_pending => switch (startWindowTransition(self, transition_index)) {
                    .started => transition_index += 1,
                    .removed => {},
                    .not_ready => {
                        if (self.animation_now - transition.start >= WindowAnimation.target_wait_nanoseconds) {
                            destroyWindowTransition(self, transition_index);
                        } else transition_index += 1;
                    },
                },
                .animating => {
                    if (WindowAnimation.linearProgress(
                        transition.start,
                        self.animation_now,
                        transition.duration,
                    ) == std.math.maxInt(u32)) {
                        destroyWindowTransition(self, transition_index);
                    } else if (transition.target_dirty) {
                        if (refreshWindowTransitionTarget(self, transition_index)) {
                            transition_index += 1;
                        }
                    } else {
                        transition_index += 1;
                    }
                },
            }
        }
        var workspace_index: usize = 0;
        while (workspace_index < self.workspace_transitions.items.len) {
            const transition = self.workspace_transitions.items[workspace_index];
            if (hasMappedClientPopup(self) or
                (transition.phase == .animating and WindowAnimation.linearProgress(
                    transition.start,
                    self.animation_now,
                    WindowAnimation.fade_duration_nanoseconds,
                ) == std.math.maxInt(u32)))
            {
                destroyWorkspaceTransition(self, workspace_index);
            } else {
                workspace_index += 1;
            }
        }
    }
    const force_composed_cursor = self.needsComposedCursorFrame(render_output.protocol_id);
    self.prepareOutputCursorFrame(render_output, force_composed_cursor);
    const paint_primary_cursor = render_output.cursor_state == .software or
        render_output.cursor_state == .deactivating;
    const render_target = render_output.backend.acquire() orelse {
        increment(&render_output.frame_statistics.acquire_retries);
        render_output.repaint_needed = true;
        return;
    };
    errdefer render_output.backend.cancel();
    render_output.beginFrame(render_start_nanoseconds);
    errdefer render_output.clearPendingFrame();
    const output = self.outputs.get(render_output.protocol_id).?;
    output.beginFrame();
    errdefer output.cancelFrame();
    const position = output.logicalPosition();
    var frame_damage = Region.init();
    defer frame_damage.deinit();
    try frame_damage.copyFrom(&render_output.damage);
    render_output.damage.clear();
    // CPU captures read the live persistent target, so every dependency must
    // be repainted. Vulkan reuses captures keyed by preceding scene content.
    if (!self.renderer.supportsBackdropCaptureReuse()) {
        self.expandBackdropBlurDamage(render_output, output, &frame_damage, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnresolvedBlurSource => {
                const size = render_output.backend.modeSize();
                frame_damage.setRectangle(0, 0, size.width, size.height);
            },
        };
    }
    // Buffer-age repair must retain the post-effect damage as this frame's new
    // damage while adding only the acquired buffer's backlog to the redraw.
    try render_output.backend.repairDamage(&frame_damage);
    const damage = if (render_output.backend.persistentRenderTarget() and
        self.renderer.supportsPartialDamage())
        try self.outputDamageRectangles(render_output, &frame_damage)
    else
        null;
    const scale = render_output.backend.renderScale();
    const origin: render.Position = .{ .x = position.x, .y = position.y };
    self.renderer.beginFrame(
        render_target,
        scale,
        origin,
        damage,
        render_output.color_description,
    ) catch |err| {
        log.err(
            "output renderer setup failed for {d}x{d} target: {t}",
            .{ render_target.size().width, render_target.size().height, err },
        );
        return err;
    };
    var renderer_frame_active = true;
    errdefer if (renderer_frame_active) self.renderer.cancelFrame();
    var next_backdrop_capture_id: u32 = 1;
    const frame: OutputFrame = .{
        .render_output = render_output,
        .output = output,
        .visible_rect = output.logicalRect(),
        .track_visibility = true,
        .presentation_damage = &frame_damage,
        .next_backdrop_capture_id = &next_backdrop_capture_id,
    };
    const clear_command = [_]render.Command{.{
        .clear = outputClearColor(self.palette, self.session_lock.isLocked()),
    }};
    try self.renderCommands(&frame, &clear_command);
    if (self.session_lock.isLocked()) {
        try self.renderSessionLockContents(&frame, paint_primary_cursor, true);
        try self.selectFrameOutputColorDescription(render_output, null);
        self.scheduleCursorFallbackAfterColorChange(render_output);
        renderer_frame_active = false;
        const completion = self.renderer.finishFrameScanout(
            outputStatisticsTag(render_output.protocol_id),
        ) catch |err| {
            log.err("session-lock renderer frame completion failed: {t}", .{err});
            return err;
        };
        render_output.frame_statistics.addFrameCompletion(completion);
        self.collectGpuTimings();
        const render_fence_fd = completion.sync_file_fd;
        defer if (render_fence_fd) |fd| {
            _ = std.c.close(fd);
        };
        return self.presentSessionLockFrame(
            &frame,
            render_fence_fd,
            .{
                .output = render_output.protocol_id,
                .target = render_target,
                .primary_cursor_painted = paint_primary_cursor,
                .tablet_cursors_painted = true,
            },
        );
    }

    const desktop_contents = self.renderDesktopContents(&frame, paint_primary_cursor, true) catch |err| {
        log.err("desktop frame assembly failed: {t}", .{err});
        return err;
    };
    const top_fullscreen = desktop_contents.top_fullscreen;
    try self.selectFrameOutputColorDescription(
        render_output,
        self.renderer.preferredOutputTransfer(),
    );
    self.scheduleCursorFallbackAfterColorChange(render_output);
    const fifo_barrier = Surface.hasFifoBarrierForOutput(
        self.compositor.surfaceStore(),
        output,
    );
    const allow_tearing = if (top_fullscreen) |window_id|
        if (self.scene.windowSurface(window_id)) |surface_id|
            Surface.currentPresentationHint(
                self.compositor.surfaceStore(),
                surface_id,
            ) == .async and !fifo_barrier
        else
            false
    else
        false;
    var presented: ?presentation.Info = null;
    var direct_scanout = false;
    if (!force_composed_cursor) switch (self.renderer.directScanoutCandidate()) {
        .candidate => |candidate| {
            increment(&render_output.frame_statistics.direct_scanout_candidates);
            switch (render_output.backend.tryDirectScanout(candidate, allow_tearing)) {
                .accepted => {
                    self.renderer.finishFrameDirectScanout();
                    renderer_frame_active = false;
                    direct_scanout = true;
                    const scanout_format = render.DmabufFormat.fromFourcc(
                        candidate.dmabuf.?.format,
                    ) orelse unreachable;
                    render_output.commitFrame(
                        .direct_scanout,
                        &frame_damage,
                        scanout_format,
                        null,
                    );
                },
                .rejected => |reason| render_output.frame_statistics.rejectDirectScanout(reason),
            }
        },
        .rejected => |reason| render_output.frame_statistics.rejectDirectScanout(reason),
    };
    var overlay_destination: ?render.Rect = null;
    if (!direct_scanout) {
        if (!force_composed_cursor) switch (self.renderer.overlayScanoutCandidate()) {
            .candidate => |candidate| {
                increment(&render_output.frame_statistics.overlay_scanout_candidates);
                switch (render_output.backend.validateOverlayScanout(candidate)) {
                    .accepted => overlay_destination = candidate.destination,
                    .rejected => |reason| {
                        render_output.frame_statistics.rejectOverlayScanout(reason);
                    },
                }
            },
            .rejected => |reason| render_output.frame_statistics.rejectOverlayScanout(reason),
        };
        renderer_frame_active = false;
        const gpu_sample_tag = outputStatisticsTag(render_output.protocol_id);
        const completion = (if (overlay_destination != null)
            self.renderer.finishFrameScanoutWithoutTopmost(gpu_sample_tag)
        else
            self.renderer.finishFrameScanout(gpu_sample_tag)) catch |err| {
            log.err(
                "renderer frame completion failed (overlay={any}): {t}",
                .{ overlay_destination != null, err },
            );
            return err;
        };
        render_output.frame_statistics.addFrameCompletion(completion);
        self.collectGpuTimings();
        const render_fence_fd = completion.sync_file_fd;
        defer if (render_fence_fd) |fd| {
            _ = std.c.close(fd);
        };
        presented = if (overlay_destination) |destination| overlay_presented: {
            const result = render_output.backend.presentValidatedOverlay(
                &frame_damage,
                render_fence_fd,
                allow_tearing,
            ) catch |err| switch (err) {
                error.OutputColorFallback => {
                    render_output.discardFrame();
                    output.cancelFrame();
                    try self.refreshRenderOutputColorDescription(render_output);
                    self.damageFullOutput(render_output);
                    return;
                },
                error.OutputBusy => {
                    if (!render_output.retryOutputBusy()) return error.InvalidTarget;
                    render_output.backend.cancel();
                    render_output.discardFrame();
                    output.cancelFrame();
                    self.damageFullOutput(render_output);
                    return;
                },
                error.OverlayCommitFailed => {
                    render_output.discardFrame();
                    output.cancelFrame();
                    render_output.frame_statistics.rejectOverlayScanout(.page_flip_failed);
                    self.damageFullOutput(render_output);
                    return;
                },
                else => {
                    log.err("validated overlay presentation failed: {t}", .{err});
                    return error.InvalidTarget;
                },
            };
            preservePromotedDamage(
                &render_output.damage,
                destination,
                render_output.backend.modeSize(),
            );
            break :overlay_presented result;
        } else render_output.backend.present(
            &frame_damage,
            render_fence_fd,
            allow_tearing,
        ) catch |err| switch (err) {
            error.OutputColorFallback => {
                render_output.discardFrame();
                output.cancelFrame();
                try self.refreshRenderOutputColorDescription(render_output);
                self.damageFullOutput(render_output);
                return;
            },
            error.OutputBusy => {
                if (!render_output.retryOutputBusy()) return error.InvalidTarget;
                render_output.backend.cancel();
                render_output.discardFrame();
                output.cancelFrame();
                self.damageFullOutput(render_output);
                return;
            },
            else => {
                log.err("composited output presentation failed: {t}", .{err});
                return error.InvalidTarget;
            },
        };
        render_output.commitFrame(
            if (overlay_destination != null) .overlay_scanout else .composited,
            &frame_damage,
            render_output.backend.compositedScanoutFormat(),
            render_fence_fd,
        );
    }
    self.rememberSampledSurfaces(render_output);
    output.endFrame();
    self.color_management.refreshPreferred();
    self.foreign_toplevel_list.syncOutput(render_output.protocol_id);

    if (!desktop_contents.lower_layers_occluded) {
        self.submitLayerSurfaces(output, .background);
        self.submitLayerSurfaces(output, .bottom);
        if (top_fullscreen != null) self.submitLayerSurfaces(output, .top);
    }
    var fullscreen_reached = top_fullscreen == null;
    var nodes = self.scene.nodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
            if (!window_entry.window.mapped) continue;
            if (top_fullscreen) |id| {
                if (!std.meta.eql(window_entry.id, id)) continue;
                fullscreen_reached = true;
            }
            if (transitionIndex(self, window_entry.id)) |index| {
                const transition = self.window_transitions.items[index];
                if (transition.phase == .animating and !transition.target_dirty and
                    std.meta.eql(transition.output_id, render_output.protocol_id))
                {
                    self.submitCapturedWindowDecorations(output, window_entry.id, .below);
                    self.submitCapturedSurfaceTree(output, window_entry.window.surface_id);
                    self.submitCapturedWindowDecorations(output, window_entry.id, .above);
                }
            } else {
                self.submitWindowDecorations(output, window_entry.id, .below);
                self.submitSurfaceTree(output, window_entry.window.surface_id);
                self.submitWindowDecorations(output, window_entry.id, .above);
                self.submitWindowPopups(output, window_entry.id);
            }
        },
        .shell_surface => |shell_entry| {
            if (!fullscreen_reached or !shell_entry.shell_surface.mapped) continue;
            self.submitSurfaceTree(output, shell_entry.shell_surface.surface_id);
        },
    };
    if (top_fullscreen == null) self.submitLayerSurfaces(output, .top);
    self.submitLayerSurfaces(output, .overlay);
    self.submitLayerPopups(output);
    var input_popups = self.input_method.popupIterator();
    while (input_popups.next()) |popup| self.submitSurfaceTree(output, popup.surface_id);
    const drag_icon = self.data_device.iconInfo();
    if (drag_icon) |info| self.submitSurfaceTree(output, info.surface_id);
    if (paint_primary_cursor) self.submitSeatCursor(output, &self.seat, false);
    self.submitTabletCursors(output, false);
    Surface.clearFifoBarriersForOutput(self.compositor.surfaceStore(), output);
    self.finishRepaintIfIdle();
    if (presented) |info| outputPresented(render_output, info);
    self.captureOutputFrame(
        render_output.protocol_id,
        if (!direct_scanout and overlay_destination == null) .{
            .output = render_output.protocol_id,
            .target = render_target,
            .primary_cursor_painted = paint_primary_cursor,
            .tablet_cursors_painted = true,
        } else null,
    );
    for (self.window_transitions.items) |transition| {
        if (std.meta.eql(transition.output_id, render_output.protocol_id)) {
            self.damageFullOutput(render_output);
            break;
        }
    }
    if (workspaceTransitionIndex(self, render_output.protocol_id) != null) {
        self.damageFullOutput(render_output);
    }
    self.refreshKeyboardFocus();
}

fn needsComposedCursorFrame(self: *Self, output_id: OutputLayout.Id) bool {
    const cursor = self.seatCursorInfo(&self.seat, self.session_lock.isLocked()) orelse
        return false;
    const output = self.outputs.get(output_id) orelse return false;
    const output_rect = output.logicalRect();
    const local_bounds = if (self.cursorBounds(cursor)) |bounds| local: {
        const clipped = bounds.intersection(output_rect) orelse return false;
        break :local clipped.translated(0 -| output_rect.x, 0 -| output_rect.y);
    } else null;
    return (self.image_copy_capture_initialized and
        self.image_copy_capture.needsComposedCursorFrame(output_id)) or
        (self.screencopy_initialized and
            self.screencopy.needsComposedCursorFrame(output_id, local_bounds));
}

fn captureOutputFrame(
    self: *Self,
    output_id: OutputLayout.Id,
    source: ?ComposedCaptureSource,
) void {
    std.debug.assert(self.composed_capture_source == null);
    self.composed_capture_source = source;
    defer self.composed_capture_source = null;
    if (self.image_copy_capture_initialized) self.image_copy_capture.captureOutput(output_id);
    if (self.screencopy_initialized) self.screencopy.captureOutput(output_id);
}

fn selectFrameOutputColorDescription(
    self: *Self,
    render_output: *RenderOutput,
    transfer: ?render.TransferFunction,
) !void {
    _ = render_output.backend.selectOutputTransfer(transfer);
    try self.refreshRenderOutputColorDescription(render_output);
    self.renderer.setOutputColorDescription(render_output.color_description);
    self.renderer.setOutputCalibration(render_output.output_calibration);
}

const DesktopContents = struct {
    top_fullscreen: ?Scene.Id,
    lower_layers_occluded: bool,
};

fn renderDesktopContents(
    self: *Self,
    frame: *const OutputFrame,
    paint_primary_cursor: bool,
    paint_tablet_cursors: bool,
) Renderer.Error!DesktopContents {
    const fullscreen_entry = self.topFullscreenForOutput(frame.visible_rect);
    const top_fullscreen = if (fullscreen_entry) |entry| entry.id else null;
    const lower_layers_occluded = if (fullscreen_entry) |entry|
        self.fullscreenOccludesLowerLayers(entry.window, frame.visible_rect)
    else
        false;
    if (!lower_layers_occluded) {
        try self.renderLayerSurfaces(frame, .background);
        if (self.hasBackgroundEffect()) {
            const blur = Scene.background_blur;
            const cache_command = [_]render.Command{.{ .backdrop_capture = .{
                .id = try allocateBackdropCaptureId(frame),
                .rect = frame.visible_rect,
                .radius = blur.radius,
                .downsample_level = blur.downsample_level,
                .finish = blur.finish,
                .base = true,
            } }};
            try self.renderCommands(frame, &cache_command);
        }
        try self.renderLayerSurfaces(frame, .bottom);
        if (top_fullscreen != null) try self.renderLayerSurfaces(frame, .top);
    }
    var fullscreen_reached = top_fullscreen == null;
    var nodes = self.scene.nodeIterator();
    while (nodes.next()) |entry| switch (entry) {
        .window => |window_entry| {
            if (!window_entry.window.mapped) continue;
            if (top_fullscreen) |id| {
                if (!std.meta.eql(window_entry.id, id)) continue;
                fullscreen_reached = true;
            }
            try self.renderWindow(frame, window_entry.id, window_entry.window);
        },
        .shell_surface => |shell_entry| {
            if (!fullscreen_reached or !shell_entry.shell_surface.mapped) continue;
            try self.renderSurfaceTree(
                frame,
                shell_entry.shell_surface.surface_id,
                shell_entry.shell_surface.position.x,
                shell_entry.shell_surface.position.y,
                null,
                null,
            );
        },
    };
    if (top_fullscreen == null) {
        try self.renderDetachedWindowTransitions(frame);
        try self.renderTilingDragPreview(frame);
        try self.renderLayerSurfaces(frame, .top);
    }
    try self.renderLayerSurfaces(frame, .overlay);
    try self.renderLayerPopups(frame);

    self.input_method.refreshPopups();
    var input_popups = self.input_method.popupIterator();
    while (input_popups.next()) |popup| {
        try self.renderSurfaceTree(
            frame,
            popup.surface_id,
            popup.position.x,
            popup.position.y,
            null,
            null,
        );
    }

    const drag_icon = self.data_device.iconInfo();
    if (drag_icon) |info| {
        try self.renderSurfaceTree(
            frame,
            info.surface_id,
            info.x,
            info.y,
            null,
            null,
        );
    }

    try self.renderWorkspaceTransition(frame);
    if (paint_primary_cursor) try self.renderSeatCursor(frame, &self.seat, false);
    if (paint_tablet_cursors) try self.renderTabletCursors(frame, false);
    return .{
        .top_fullscreen = top_fullscreen,
        .lower_layers_occluded = lower_layers_occluded,
    };
}

fn fullscreenOccludesLowerLayers(
    self: *Self,
    window: *const Scene.Window,
    output_rect: render.Rect,
) bool {
    const surfaces = self.compositor.surfaceStore();
    const buffer = Surface.currentBuffer(surfaces, window.surface_id) orelse return false;
    return window_geometry.fullscreenRootOccludesOutput(
        window,
        buffer.logical_size,
        surfaceFullyOpaque(surfaces, window.surface_id, buffer),
        output_rect,
    );
}

fn hasBackgroundEffect(self: *Self) bool {
    const surfaces = self.compositor.surfaceStore();
    var iterator = surfaces.iterator();
    while (iterator.next()) |entry| {
        if (Surface.currentBlurRegion(surfaces, entry.id) == null) continue;
        const buffer = Surface.currentBuffer(surfaces, entry.id) orelse continue;
        if (!surfaceFullyOpaque(surfaces, entry.id, buffer)) return true;
    }
    return false;
}

fn presentSessionLockFrame(
    self: *Self,
    frame: *const OutputFrame,
    render_fence_fd: ?std.posix.fd_t,
    capture_source: ?ComposedCaptureSource,
) Renderer.Error!void {
    const lock_surface = self.session_lock.surfaceForOutput(frame.render_output.protocol_id);
    const presented = frame.render_output.backend.present(
        frame.presentation_damage.?,
        render_fence_fd,
        false,
    ) catch |err| switch (err) {
        error.OutputColorFallback => {
            frame.render_output.discardFrame();
            frame.output.cancelFrame();
            try self.refreshRenderOutputColorDescription(frame.render_output);
            self.damageFullOutput(frame.render_output);
            return;
        },
        error.OutputBusy => {
            if (!frame.render_output.retryOutputBusy()) return error.InvalidTarget;
            frame.render_output.backend.cancel();
            frame.render_output.discardFrame();
            frame.output.cancelFrame();
            self.damageFullOutput(frame.render_output);
            return;
        },
        else => {
            log.err("session-lock output presentation failed: {t}", .{err});
            return error.InvalidTarget;
        },
    };
    frame.render_output.commitFrame(
        .composited,
        frame.presentation_damage.?,
        frame.render_output.backend.compositedScanoutFormat(),
        render_fence_fd,
    );
    frame.render_output.lock_frame_pending = true;
    self.rememberSampledSurfaces(frame.render_output);
    frame.output.endFrame();
    self.color_management.refreshPreferred();
    self.foreign_toplevel_list.syncOutput(frame.render_output.protocol_id);
    if (lock_surface) |info| self.submitSurfaceTree(frame.output, info.surface_id);
    if (frame.render_output.cursor_state == .software or
        frame.render_output.cursor_state == .deactivating)
        self.submitSeatCursor(frame.output, &self.seat, true);
    self.submitTabletCursors(frame.output, true);
    Surface.clearFifoBarriersForOutput(self.compositor.surfaceStore(), frame.output);
    self.finishRepaintIfIdle();
    if (presented) |info| outputPresented(frame.render_output, info);
    self.captureOutputFrame(frame.render_output.protocol_id, capture_source);
    self.refreshKeyboardFocus();
}

fn renderSessionLockContents(
    self: *Self,
    frame: *const OutputFrame,
    paint_primary_cursor: bool,
    paint_tablet_cursors: bool,
) Renderer.Error!void {
    const lock_surface = self.session_lock.surfaceForOutput(frame.render_output.protocol_id);
    if (lock_surface) |info| {
        try self.renderSurfaceTree(
            frame,
            info.surface_id,
            info.position.x,
            info.position.y,
            null,
            null,
        );
    }

    if (paint_primary_cursor) try self.renderSeatCursor(frame, &self.seat, true);
    if (paint_tablet_cursors) try self.renderTabletCursors(frame, true);
}

fn refreshKeyboardFocus(self: *Self) void {
    if (self.session_lock.isLocked()) {
        const focus = self.session_lock.keyboardFocus();
        self.seat.setKeyboardFocus(focus);
        self.syncXwaylandFocus(null);
        return;
    }
    const default_focus = self.layer_shell.keyboardFocus(
        self.xdg_shell.popupKeyboardFocus(),
    ) orelse
        self.xwayland_override_redirect_focus orelse
        self.window_manager.focusedSurface() orelse self.scene.focusedSurface();
    self.seat.setKeyboardFocus(default_focus);
    self.syncXwaylandFocus(default_focus);
}

fn renderSeatCursor(
    self: *Self,
    frame: *const OutputFrame,
    seat: *Seat,
    locked: bool,
) Renderer.Error!void {
    const info = self.seatCursorInfo(seat, locked) orelse return;
    try self.renderCursor(frame, info);
}

fn renderTabletCursors(
    self: *Self,
    frame: *const OutputFrame,
    locked: bool,
) Renderer.Error!void {
    var cursors = self.tablet.cursorIterator();
    while (cursors.next()) |info| {
        if (!self.tabletCursorVisible(info.focus_surface, locked)) continue;
        try self.renderCursor(frame, info.cursor);
    }
}

fn renderCursor(
    self: *Self,
    frame: *const OutputFrame,
    info: Seat.CursorInfo,
) Renderer.Error!void {
    switch (info) {
        .surface => |surface| try self.renderSurfaceTree(
            frame,
            surface.surface_id,
            surface.x,
            surface.y,
            null,
            null,
        ),
        .shape => |shape| {
            const command = [_]render.Command{.{ .image = .{
                .x = shape.x,
                .y = shape.y,
                .size = shape.buffer.size,
                .buffer = shape.buffer,
            } }};
            try self.renderCommands(frame, &command);
        },
    }
}

fn submitSeatCursor(self: *Self, output: *Output, seat: *Seat, locked: bool) void {
    const info = self.seatCursorInfo(seat, locked) orelse return;
    self.submitCursor(output, info);
}

fn submitTabletCursors(self: *Self, output: *Output, locked: bool) void {
    var cursors = self.tablet.cursorIterator();
    while (cursors.next()) |info| {
        if (!self.tabletCursorVisible(info.focus_surface, locked)) continue;
        self.submitCursor(output, info.cursor);
    }
}

fn submitCursor(self: *Self, output: *Output, info: Seat.CursorInfo) void {
    switch (info) {
        .surface => |surface| self.submitSurfaceTree(output, surface.surface_id),
        .shape => {},
    }
}

fn seatCursorInfo(self: *Self, seat: *Seat, locked: bool) ?Seat.CursorInfo {
    if (locked) {
        const surface_id = seat.pointerFocusedSurface() orelse return null;
        const root = self.subcompositor.rootSurface(surface_id);
        if (!self.session_lock.ownsSurface(root)) return null;
    }
    return seat.cursorInfo();
}

fn tabletCursorVisible(self: *Self, focus_surface: Surface.Id, locked: bool) bool {
    if (!locked) return true;
    const root = self.subcompositor.rootSurface(focus_surface);
    return self.session_lock.ownsSurface(root);
}

fn finishRepaintIfIdle(self: *Self) void {
    var render_outputs = self.render_outputs.iterator();
    while (render_outputs.next()) |entry| {
        const render_output = entry.value.*;
        if (render_output.repaint_needed or render_output.render_scheduled) return;
    }
    self.fractional_scale.refresh();
    self.refreshSurfaceOutputPreferences();
    Surface.discardUnsubmittedFeedback(self.compositor.surfaceStore());
}

fn refreshSurfaceOutputPreferences(self: *Self) void {
    const default_scale = self.outputs.get(self.primaryRenderOutput().protocol_id).?.clientScale();
    const surfaces = self.compositor.surfaceStore();
    var surface_iterator = surfaces.iterator();
    while (surface_iterator.next()) |surface_entry| {
        var preferred_scale = default_scale;
        var found = false;
        var outputs = self.outputs.iterator();
        while (outputs.next()) |output_entry| {
            if (!output_entry.output.containsSurface(surface_entry.id)) continue;
            const output_scale = output_entry.output.clientScale();
            if (!found or output_scale > preferred_scale) preferred_scale = output_scale;
            found = true;
        }
        Surface.setPreferredBufferScale(surfaces, surface_entry.id, preferred_scale);
    }
}

fn renderLayerSurfaces(
    self: *Self,
    frame: *const OutputFrame,
    layer: Scene.Layer,
) Renderer.Error!void {
    var surfaces = self.scene.layerSurfaceIterator(layer);
    while (surfaces.next()) |entry| {
        const layer_surface = entry.layer_surface;
        if (!layer_surface.mapped) continue;
        const capture_id = try self.renderSurfaceTreeCapture(frame, layer_surface.surface_id, layer_surface.position.x, layer_surface.position.y, null, null);
        try self.renderSurfaceTreeContents(
            frame,
            layer_surface.surface_id,
            layer_surface.position.x,
            layer_surface.position.y,
            null,
            null,
            capture_id,
        );
    }
}

fn renderTilingDragPreview(
    self: *Self,
    frame: *const OutputFrame,
) Renderer.Error!void {
    const preview = self.window_manager.tilingDragPreview() orelse return;
    const command = [_]render.Command{tilingDragPreviewCommand(.{
        .x = preview.x,
        .y = preview.y,
        .width = preview.size.width,
        .height = preview.size.height,
    }, self.palette.tiling_drag_preview)};
    try self.renderCommands(frame, &command);
}

fn tilingDragPreviewCommand(rect: render.Rect, color: Config.Color) render.Command {
    std.debug.assert(rect.width > 0 and rect.height > 0);
    return .{ .shadow = .{
        .rect = rect,
        .corner_radius = 12,
        .blur_radius = 20,
        .spread = 0,
        .color = renderColor(color),
    } };
}

fn outputClearColor(palette: theme.Palette, locked: bool) render.Color {
    if (locked) return render.Color.rgba(0, 0, 0, 0xff);
    return renderColor(palette.desktop_background);
}

fn submitLayerSurfaces(self: *Self, output: *Output, layer: Scene.Layer) void {
    var surfaces = self.scene.layerSurfaceIterator(layer);
    while (surfaces.next()) |entry| {
        if (entry.layer_surface.mapped) {
            self.submitSurfaceTree(output, entry.layer_surface.surface_id);
        }
    }
}

fn renderLayerPopups(self: *Self, frame: *const OutputFrame) Renderer.Error!void {
    inline for (.{
        Scene.Layer.background,
        Scene.Layer.bottom,
        Scene.Layer.top,
        Scene.Layer.overlay,
    }) |layer| {
        var roots = self.scene.layerSurfaceIterator(layer);
        while (roots.next()) |root| {
            var popups = self.scene.layerPopupIterator(root.id);
            while (popups.next()) |entry| {
                if (!entry.popup.mapped) continue;
                const buffer = Surface.currentBuffer(
                    self.compositor.surfaceStore(),
                    entry.popup.surface_id,
                ) orelse continue;
                const geometry = entry.popup.content_geometry orelse Scene.ContentGeometry{
                    .size = buffer.logical_size,
                };
                try self.renderSurfaceTree(
                    frame,
                    entry.popup.surface_id,
                    entry.position.x -| geometry.offset.x,
                    entry.position.y -| geometry.offset.y,
                    null,
                    null,
                );
            }
        }
    }
}

fn submitLayerPopups(self: *Self, output: *Output) void {
    inline for (.{
        Scene.Layer.background,
        Scene.Layer.bottom,
        Scene.Layer.top,
        Scene.Layer.overlay,
    }) |layer| {
        var roots = self.scene.layerSurfaceIterator(layer);
        while (roots.next()) |root| {
            var popups = self.scene.layerPopupIterator(root.id);
            while (popups.next()) |entry| {
                if (entry.popup.mapped) self.submitSurfaceTree(output, entry.popup.surface_id);
            }
        }
    }
}

fn renderCommands(
    self: *Self,
    frame: *const OutputFrame,
    commands: []const render.Command,
) Renderer.Error!void {
    _ = frame;
    try self.renderer.append(commands);
}

fn scalePremultipliedColor(color: render.Color, opacity: u32) render.Color {
    const maximum: u64 = std.math.maxInt(u32);
    return .{
        .red = @intCast((@as(u64, color.red) * opacity + maximum / 2) / maximum),
        .green = @intCast((@as(u64, color.green) * opacity + maximum / 2) / maximum),
        .blue = @intCast((@as(u64, color.blue) * opacity + maximum / 2) / maximum),
        .alpha = @intCast((@as(u64, color.alpha) * opacity + maximum / 2) / maximum),
    };
}

fn effectsWithOpacity(effects: Scene.Effects, opacity: u32) Scene.Effects {
    var result = effects;
    if (result.ambient_shadow) |*shadow| {
        shadow.color = scalePremultipliedColor(shadow.color, opacity);
    }
    if (result.key_shadow) |*shadow| {
        shadow.color = scalePremultipliedColor(shadow.color, opacity);
    }
    return result;
}

fn bordersWithOpacity(borders: ?Scene.Borders, opacity: u32) ?Scene.Borders {
    var result = borders orelse return null;
    result.color = scalePremultipliedColor(result.color, opacity);
    return result;
}

test "transition opacity scales every premultiplied color component" {
    const color = render.Color.rgba(180, 90, 45, 128);
    try std.testing.expectEqual(
        render.Color.rgba(0, 0, 0, 0),
        scalePremultipliedColor(color, 0),
    );
    try std.testing.expectEqual(
        color,
        scalePremultipliedColor(color, std.math.maxInt(u32)),
    );
    const half = scalePremultipliedColor(color, std.math.maxInt(u32) / 2);
    try std.testing.expect(half.red <= half.alpha);
    try std.testing.expect(half.green <= half.alpha);
    try std.testing.expect(half.blue <= half.alpha);
    try std.testing.expect(half.alpha >= 63 and half.alpha <= 64);
}

fn renderShadow(
    self: *Self,
    frame: *const OutputFrame,
    rect: render.Rect,
    corner_radius: u32,
    shadow: Scene.Shadow,
    clip: ?render.Rect,
) Renderer.Error!void {
    const shadow_command = [_]render.Command{
        .{ .shadow = .{
            .rect = rect.translated(shadow.offset.x, shadow.offset.y),
            .corner_radius = corner_radius,
            .blur_radius = shadow.blur_radius,
            .spread = shadow.spread,
            .color = shadow.color,
            .cutout = .{
                .rect = rect,
                .radius = corner_radius,
            },
            .clip = clip,
        } },
    };
    try self.renderCommands(frame, &shadow_command);
}

fn renderShadows(
    self: *Self,
    frame: *const OutputFrame,
    rect: render.Rect,
    effects: Scene.Effects,
    borders: ?Scene.Borders,
    clip: ?render.Rect,
) Renderer.Error!void {
    const caster = window_geometry.shadowCaster(rect, borders, effects.corner_radius);
    if (effects.ambient_shadow) |shadow| {
        try self.renderShadow(frame, caster.rect, caster.corner_radius, shadow, clip);
    }
    if (effects.key_shadow) |shadow| {
        try self.renderShadow(frame, caster.rect, caster.corner_radius, shadow, clip);
    }
}

fn renderRetainedSnapshot(
    self: *Self,
    frame: *const OutputFrame,
    source: render.ImageSource,
    destination: render.Rect,
    source_rect: ?render.SourceRect,
    clip: ?render.Rect,
    rounded_clip: ?render.RoundedClip,
) Renderer.Error!void {
    try self.renderCommands(frame, &.{.{ .crossfade = .{
        .destination = destination,
        .old = source,
        .new = source,
        .old_source = source_rect,
        .new_source = source_rect,
        .factor = 0,
        .clip = clip,
        .rounded_clip = rounded_clip,
    } }});
}

fn renderWorkspaceTransition(self: *Self, frame: *const OutputFrame) Renderer.Error!void {
    const index = workspaceTransitionIndex(self, frame.render_output.protocol_id) orelse return;
    const transition = &self.workspace_transitions.items[index];
    try self.renderCommands(frame, &.{.{ .crossfade = .{
        .destination = renderAnimationRect(transition.rect),
        .old = transition.old.source,
        .new = transition.transparent.source,
        .factor = if (transition.phase == .animating)
            WindowAnimation.linearProgress(
                transition.start,
                self.animation_now,
                WindowAnimation.fade_duration_nanoseconds,
            )
        else
            0,
    } }});
}

fn renderElasticGrowthSnapshot(
    self: *Self,
    frame: *const OutputFrame,
    transition: *const WindowTransition,
    animated_destination: render.Rect,
    rounded_clip: ?render.RoundedClip,
) Renderer.Error!void {
    const old = transition.old_rect;
    const target = transition.target_rect;
    const horizontal = target.width > old.width and target.height == old.height;
    const vertical = target.height > old.height and target.width == old.width;
    if (!horizontal and !vertical) {
        try self.renderRetainedSnapshot(
            frame,
            transition.old.source,
            animated_destination,
            null,
            null,
            rounded_clip,
        );
        return;
    }

    const old_start = if (horizontal) old.x else old.y;
    const old_length = if (horizontal) old.width else old.height;
    const animated_start = if (horizontal) animated_destination.x else animated_destination.y;
    const animated_length = if (horizontal) animated_destination.width else animated_destination.height;
    const target_start = if (horizontal) target.x else target.y;
    const target_length = if (horizontal) target.width else target.height;
    const old_end = @as(i64, old_start) + old_length;
    const target_end = @as(i64, target_start) + target_length;
    const moving_end = @abs(target_end - old_end) >=
        @abs(@as(i64, target_start) - old_start);
    const slices = WindowAnimation.growthSlices(
        old_start,
        old_length,
        animated_start,
        animated_length,
        moving_end,
    );
    const source_size = transition.old.source.size();
    const source_axis_length = if (horizontal) source_size.width else source_size.height;
    const source_scale = @as(f64, @floatFromInt(source_axis_length)) /
        @as(f64, @floatFromInt(old_length));
    for (slices.slice()) |slice| {
        const source_start = if (slice.source_start == 0)
            0
        else
            @as(f64, @floatFromInt(slice.source_start)) * source_scale;
        const source_offset_end = slice.source_start + slice.source_length;
        const source_end = if (source_offset_end == old_length)
            @as(f64, @floatFromInt(source_axis_length))
        else
            @as(f64, @floatFromInt(source_offset_end)) * source_scale;
        const source: render.SourceRect = if (horizontal) .{
            .x = source_start,
            .y = 0,
            .width = source_end - source_start,
            .height = @floatFromInt(source_size.height),
        } else .{
            .x = 0,
            .y = source_start,
            .width = @floatFromInt(source_size.width),
            .height = source_end - source_start,
        };
        const destination: render.Rect = if (horizontal) .{
            .x = slice.destination_start,
            .y = animated_destination.y,
            .width = slice.destination_length,
            .height = animated_destination.height,
        } else .{
            .x = animated_destination.x,
            .y = slice.destination_start,
            .width = animated_destination.width,
            .height = slice.destination_length,
        };
        try self.renderRetainedSnapshot(
            frame,
            transition.old.source,
            destination,
            source,
            animated_destination,
            rounded_clip,
        );
    }
}

fn windowTransitionOpacity(
    kind: @FieldType(WindowTransition, "kind"),
    phase: @FieldType(WindowTransition, "phase"),
    start: i96,
    now: i96,
    duration: u64,
) u32 {
    return switch (kind) {
        .reflow => std.math.maxInt(u32),
        .appearance => WindowAnimation.appearanceProgress(start, now),
        .disappearance => if (phase == .waiting)
            std.math.maxInt(u32)
        else
            std.math.maxInt(u32) - WindowAnimation.disappearanceProgress(
                start,
                now,
                duration,
            ),
    };
}

test "waiting disappearance retains full opacity" {
    const far_future: i96 = 10 * std.time.ns_per_s;
    const duration = WindowAnimation.normal_duration_nanoseconds;
    try std.testing.expectEqual(
        std.math.maxInt(u32),
        windowTransitionOpacity(.disappearance, .waiting, 0, far_future, duration),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u32),
        windowTransitionOpacity(.disappearance, .animating, far_future, far_future, duration),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        windowTransitionOpacity(.disappearance, .animating, 0, far_future, duration),
    );
}

fn renderWindowTransition(
    self: *Self,
    frame: *const OutputFrame,
    transition: *const WindowTransition,
    configured_effects: Scene.Effects,
    configured_borders: ?Scene.Borders,
    mark_surfaces: bool,
) Renderer.Error!void {
    if (!std.meta.eql(transition.output_id, frame.render_output.protocol_id)) return;
    const factor = if (transition.phase != .waiting)
        WindowAnimation.progress(
            transition.start,
            self.animation_now,
            transition.duration,
            transition.easing,
        )
    else
        0;
    const content_factor = if (transition.phase != .waiting)
        WindowAnimation.contentProgress(
            transition.start,
            self.animation_now,
            transition.duration,
        )
    else
        0;
    const opacity = if (!transition.opacity_transition)
        std.math.maxInt(u32)
    else
        windowTransitionOpacity(
            transition.kind,
            transition.phase,
            transition.start,
            self.animation_now,
            transition.duration,
        );
    const effects = effectsWithOpacity(configured_effects, opacity);
    const borders = bordersWithOpacity(configured_borders, opacity);
    const animated_rect = WindowAnimation.constrainSplitOuterEdge(
        WindowAnimation.interpolate(transition.old_rect, transition.target_rect, factor),
        transition.old_rect,
        transition.target_rect,
    );
    const animated_destination = renderAnimationRect(animated_rect);
    if (animated_destination.width == 0 or animated_destination.height == 0) return;
    try self.renderShadows(frame, animated_destination, effects, borders, null);
    const rounded_clip: ?render.RoundedClip = if (effects.corner_radius == 0)
        null
    else
        .{ .rect = animated_destination, .radius = effects.corner_radius };
    const target = if (transition.target) |snapshot| snapshot.source else transition.old.source;
    if (transition.kind == .reflow) {
        const old_area = @as(u64, transition.old_rect.width) * transition.old_rect.height;
        const target_area = @as(u64, transition.target_rect.width) * transition.target_rect.height;
        const target_destination = renderAnimationRect(transition.target_rect);
        const shrinking_old_source = if (target_area < old_area)
            WindowAnimation.targetSourceRect(
                transition.old_rect,
                transition.target_rect,
                transition.old.source.size(),
            )
        else
            null;
        if (target_area > old_area) {
            try self.renderElasticGrowthSnapshot(
                frame,
                transition,
                animated_destination,
                rounded_clip,
            );
            if (transition.target) |target_snapshot| {
                const reveal_rect = WindowAnimation.targetReveal(
                    transition.old_rect,
                    transition.target_rect,
                    content_factor,
                );
                const reveal = renderAnimationRect(reveal_rect);
                if (animated_destination.intersection(reveal)) |target_clip| {
                    try self.renderRetainedSnapshot(
                        frame,
                        target_snapshot.source,
                        target_destination,
                        null,
                        target_clip,
                        rounded_clip,
                    );
                }
            }
        } else if (shrinking_old_source) |old_source| {
            const old_destination = renderAnimationRect(transition.old_rect);
            try self.renderRetainedSnapshot(
                frame,
                transition.old.source,
                old_destination,
                null,
                animated_destination,
                rounded_clip,
            );
            const crossfade_factor = content_factor;
            if (crossfade_factor != 0) {
                if (transition.target) |target_snapshot| {
                    if (animated_destination.intersection(target_destination)) |target_clip| {
                        try self.renderCommands(frame, &.{.{ .crossfade = .{
                            .destination = target_destination,
                            .old = transition.old.source,
                            .new = target_snapshot.source,
                            .old_source = old_source,
                            .factor = crossfade_factor,
                            .clip = target_clip,
                            .rounded_clip = rounded_clip,
                        } }});
                    }
                }
            }
        } else {
            try self.renderCommands(frame, &.{.{ .crossfade = .{
                .destination = animated_destination,
                .old = transition.old.source,
                .new = target,
                .factor = content_factor,
                .rounded_clip = rounded_clip,
            } }});
        }
    } else {
        const content_rect = if (transition.kind == .appearance)
            transition.target_rect
        else
            transition.old_rect;
        const content_destination = renderAnimationRect(content_rect);
        const fade_factor = if (transition.kind == .appearance)
            opacity
        else
            std.math.maxInt(u32) - opacity;
        try self.renderCommands(frame, &.{.{ .crossfade = .{
            .destination = content_destination,
            .old = transition.old.source,
            .new = target,
            .factor = fade_factor,
            .clip = animated_destination,
            .rounded_clip = rounded_clip,
        } }});
    }
    try self.renderBorders(
        frame,
        animated_destination,
        borders,
        effects.corner_radius,
        null,
    );
    if (mark_surfaces and frame.track_visibility) {
        try self.markSurfaceTreeVisible(frame.output, transition.root_id);
        var below = self.scene.decorationIterator(transition.scene_id, .below);
        while (below.next()) |entry| if (entry.decoration.mapped)
            try self.markSurfaceTreeVisible(frame.output, entry.decoration.surface_id);
        var above = self.scene.decorationIterator(transition.scene_id, .above);
        while (above.next()) |entry| if (entry.decoration.mapped)
            try self.markSurfaceTreeVisible(frame.output, entry.decoration.surface_id);
    }
}

fn renderDetachedWindowTransitions(
    self: *Self,
    frame: *const OutputFrame,
) Renderer.Error!void {
    for (self.window_transitions.items) |*transition| {
        if (transition.kind != .disappearance or !transition.detached) continue;
        try self.renderWindowTransition(
            frame,
            transition,
            transition.effects orelse .{},
            transition.borders,
            false,
        );
    }
}

fn renderWindow(
    self: *Self,
    frame: *const OutputFrame,
    id: Scene.Id,
    window: *const Scene.Window,
) Renderer.Error!void {
    const root_buffer = Surface.currentBuffer(
        self.compositor.surfaceStore(),
        window.surface_id,
    ) orelse return;
    const content_geometry = window.content_geometry orelse Scene.ContentGeometry{
        .size = root_buffer.logical_size,
    };
    const content_rect = window_geometry.windowContentRect(window, content_geometry.size) orelse return;
    if (transitionIndex(self, id)) |transition_index| {
        const transition = &self.window_transitions.items[transition_index];
        if (transition.kind == .disappearance) return;
        try self.renderWindowTransition(
            frame,
            transition,
            window.effects,
            window.borders,
            true,
        );
        return;
    }
    const window_clip = if (window.clip_box) |clip_box|
        clip_box.translated(window.position.x, window.position.y)
    else
        null;
    const shadow_clip = if (window.shadow_clip_box orelse window.clip_box) |clip_box|
        clip_box.translated(window.position.x, window.position.y)
    else
        null;
    const tree_x = window.position.x -| content_geometry.offset.x;
    const tree_y = window.position.y -| content_geometry.offset.y;
    const rounded_clip: ?render.RoundedClip = if (window.effects.corner_radius == 0)
        null
    else
        .{ .rect = content_rect, .radius = window.effects.corner_radius };
    var content_visible = true;
    var content_clip = if (window.content_clip_box != null) content_rect else null;
    if (window_clip) |clip| {
        if (content_clip) |current| {
            content_clip = current.intersection(clip) orelse no_content: {
                content_visible = false;
                break :no_content null;
            };
        } else {
            content_clip = clip;
        }
    }
    var capture_id: ?u32 = null;
    if (content_visible) {
        capture_id = try self.renderSurfaceTreeCapture(
            frame,
            window.surface_id,
            tree_x,
            tree_y,
            rounded_clip,
            content_clip,
        );
    }
    try self.renderShadows(frame, content_rect, window.effects, window.borders, shadow_clip);
    try self.renderWindowDecorations(frame, id, window, .below, window_clip);
    if (content_visible) {
        try self.renderSurfaceTreeContents(
            frame,
            window.surface_id,
            tree_x,
            tree_y,
            rounded_clip,
            content_clip,
            capture_id,
        );
    }
    try self.renderBorders(
        frame,
        content_rect,
        window.borders,
        window.effects.corner_radius,
        window_clip,
    );
    try self.renderWindowDecorations(frame, id, window, .above, window_clip);
    try self.renderWindowPopups(frame, id);
}

fn renderWindowPopups(
    self: *Self,
    frame: *const OutputFrame,
    window_id: Scene.Id,
) Renderer.Error!void {
    var popups = self.scene.popupIterator(window_id);
    while (popups.next()) |entry| {
        const popup = entry.popup;
        if (!popup.mapped) continue;
        const buffer = Surface.currentBuffer(
            self.compositor.surfaceStore(),
            popup.surface_id,
        ) orelse continue;
        const content_geometry = popup.content_geometry orelse Scene.ContentGeometry{
            .size = buffer.logical_size,
        };
        try self.renderSurfaceTree(
            frame,
            popup.surface_id,
            entry.position.x -| content_geometry.offset.x,
            entry.position.y -| content_geometry.offset.y,
            null,
            null,
        );
    }
}

fn renderSurfaceTree(
    self: *Self,
    frame: *const OutputFrame,
    surface_id: Surface.Id,
    x: i32,
    y: i32,
    rounded_clip: ?render.RoundedClip,
    clip: ?render.Rect,
) Renderer.Error!void {
    const capture_id = try self.renderSurfaceTreeCapture(frame, surface_id, x, y, rounded_clip, clip);
    try self.renderSurfaceTreeContents(frame, surface_id, x, y, rounded_clip, clip, capture_id);
}

fn renderSurfaceTreeCapture(
    self: *Self,
    frame: *const OutputFrame,
    surface_id: Surface.Id,
    x: i32,
    y: i32,
    rounded_clip: ?render.RoundedClip,
    clip: ?render.Rect,
) Renderer.Error!?u32 {
    if (self.surfaceTreeBlurBounds(frame, surface_id, x, y, rounded_clip, clip)) |rect| {
        const blur = Scene.background_blur;
        const capture_id = try allocateBackdropCaptureId(frame);
        const command = [_]render.Command{.{ .backdrop_capture = .{
            .id = capture_id,
            .rect = rect,
            .radius = blur.radius,
            .downsample_level = blur.downsample_level,
            .finish = blur.finish,
        } }};
        try self.renderCommands(frame, &command);
        return capture_id;
    }
    return null;
}

fn renderSurfaceTreeContents(
    self: *Self,
    frame: *const OutputFrame,
    surface_id: Surface.Id,
    x: i32,
    y: i32,
    rounded_clip: ?render.RoundedClip,
    clip: ?render.Rect,
    capture_id: ?u32,
) Renderer.Error!void {
    if (Surface.currentBuffer(self.compositor.surfaceStore(), surface_id) == null) return;

    var stack = self.subcompositor.stackIterator(surface_id);
    while (stack.next()) |entry| switch (entry) {
        .parent => {
            const buffer = Surface.currentBuffer(
                self.compositor.surfaceStore(),
                surface_id,
            ) orelse continue;
            const surface_rect: render.Rect = .{
                .x = x,
                .y = y,
                .width = buffer.logical_size.width,
                .height = buffer.logical_size.height,
            };
            const visible_rect = surface_rect.intersection(frame.visible_rect) orelse continue;
            if (clip) |clip_rect| {
                if (visible_rect.intersection(clip_rect) == null) continue;
            }
            if (frame.track_visibility) {
                try frame.output.markSurfaceVisible(surface_id);
                Surface.markFifoBarrierVisible(
                    self.compositor.surfaceStore(),
                    surface_id,
                    frame.output,
                );
            }
            try self.renderSurfaceBackgroundEffect(
                frame,
                surface_id,
                x,
                y,
                buffer.logical_size,
                rounded_clip,
                clip,
                capture_id,
            );
            const pixel_buffer = buffer.pixelBuffer();
            const alpha_multiplier = Surface.currentAlphaMultiplier(
                self.compositor.surfaceStore(),
                surface_id,
            ) orelse std.math.maxInt(u32);
            const image_command = [_]render.Command{
                .{ .image = .{
                    .x = x,
                    .y = y,
                    .size = buffer.logical_size,
                    .buffer = pixel_buffer,
                    .sample_tag = surfaceSampleTag(surface_id),
                    .source = buffer.source,
                    .transform = renderBufferTransform(buffer.transform),
                    .rounded_clip = rounded_clip,
                    .clip = clip,
                    .is_opaque = surfaceFullyOpaque(
                        self.compositor.surfaceStore(),
                        surface_id,
                        buffer,
                    ),
                    .opaque_region = surfaceOpaqueRegion(
                        self.compositor.surfaceStore(),
                        surface_id,
                        buffer,
                        x,
                        y,
                        rounded_clip,
                        clip,
                        alpha_multiplier,
                    ),
                    .alpha_multiplier = alpha_multiplier,
                } },
            };
            try self.renderCommands(frame, &image_command);
        },
        .child => |child| try self.renderSurfaceTreeContents(
            frame,
            child.surface_id,
            x +| child.position.x,
            y +| child.position.y,
            rounded_clip,
            clip,
            capture_id,
        ),
    };
}

fn surfaceTreeBlurBounds(
    self: *Self,
    frame: *const OutputFrame,
    surface_id: Surface.Id,
    x: i32,
    y: i32,
    rounded_clip: ?render.RoundedClip,
    clip: ?render.Rect,
) ?render.Rect {
    if (Surface.currentBuffer(self.compositor.surfaceStore(), surface_id) == null) return null;
    var result: ?render.Rect = null;
    var stack = self.subcompositor.stackIterator(surface_id);
    while (stack.next()) |entry| switch (entry) {
        .parent => {
            const surfaces = self.compositor.surfaceStore();
            const buffer = Surface.currentBuffer(surfaces, surface_id) orelse continue;
            if (surfaceFullyOpaque(surfaces, surface_id, buffer)) continue;
            const region = Surface.currentBlurRegion(surfaces, surface_id) orelse continue;
            var rectangles = region.rectangleIterator();
            while (rectangles.next()) |rectangle| {
                var effect = (surfaceEffectRect(rectangle, buffer.logical_size) orelse continue).translated(x, y);
                effect = effect.intersection(frame.visible_rect) orelse continue;
                if (rounded_clip) |rounded| effect = effect.intersection(rounded.rect) orelse continue;
                if (clip) |clip_rect| effect = effect.intersection(clip_rect) orelse continue;
                result = if (result) |old| old.unionWith(effect) else effect;
            }
        },
        .child => |child| {
            if (self.surfaceTreeBlurBounds(
                frame,
                child.surface_id,
                x +| child.position.x,
                y +| child.position.y,
                rounded_clip,
                clip,
            )) |child_rect| result = if (result) |old| old.unionWith(child_rect) else child_rect;
        },
    };
    return result;
}

fn renderSurfaceBackgroundEffect(
    self: *Self,
    frame: *const OutputFrame,
    surface_id: Surface.Id,
    x: i32,
    y: i32,
    size: render.Size,
    rounded_clip: ?render.RoundedClip,
    clip: ?render.Rect,
    capture_id: ?u32,
) Renderer.Error!void {
    const blur = Scene.background_blur;
    const surfaces = self.compositor.surfaceStore();
    const buffer = Surface.currentBuffer(surfaces, surface_id) orelse return;
    if (surfaceFullyOpaque(surfaces, surface_id, buffer)) return;
    const region = Surface.currentBlurRegion(surfaces, surface_id) orelse return;
    var rectangles = region.rectangleIterator();
    while (rectangles.next()) |rectangle| {
        var effect_rect = surfaceEffectRect(rectangle, size) orelse continue;
        effect_rect = effect_rect.translated(x, y);
        if (effect_rect.intersection(frame.visible_rect) == null) continue;
        if (clip) |clip_rect| {
            if (effect_rect.intersection(clip_rect) == null) continue;
        }
        var corner_radius: u32 = 0;
        if (rounded_clip) |rounded| {
            effect_rect = effect_rect.intersection(rounded.rect) orelse continue;
            if (std.meta.eql(effect_rect, rounded.rect)) corner_radius = rounded.radius;
        }
        const backdrop_capture_id = capture_id orelse return error.InvalidTarget;
        const command = [_]render.Command{.{ .backdrop_blur = .{
            .capture_id = backdrop_capture_id,
            .rect = effect_rect,
            .corner_radius = corner_radius,
            .radius = blur.radius,
            .downsample_level = blur.downsample_level,
            .finish = blur.finish,
            .clip = clip,
        } }};
        try self.renderCommands(frame, &command);
    }
}

fn surfaceFullyOpaque(
    surfaces: *Surface.Store,
    surface_id: Surface.Id,
    buffer: *const Surface.BufferSnapshot,
) bool {
    return Surface.currentAlphaMultiplier(surfaces, surface_id) == std.math.maxInt(u32) and
        (buffer.force_opaque or Surface.currentOpaqueCoversBuffer(surfaces, surface_id));
}

fn surfaceOpaqueRegion(
    surfaces: *Surface.Store,
    surface_id: Surface.Id,
    buffer: *const Surface.BufferSnapshot,
    x: i32,
    y: i32,
    rounded_clip: ?render.RoundedClip,
    clip: ?render.Rect,
    alpha_multiplier: u32,
) render.OpaqueRegion {
    var result: render.OpaqueRegion = .{};
    if (alpha_multiplier != std.math.maxInt(u32) or rounded_clip != null or
        buffer.force_opaque or Surface.currentOpaqueCoversBuffer(surfaces, surface_id))
    {
        return result;
    }
    const region = Surface.currentOpaque(surfaces, surface_id) orelse return result;
    var rectangles = region.rectangleIterator();
    while (rectangles.next()) |rectangle| {
        var opaque_rect = (surfaceEffectRect(rectangle, buffer.logical_size) orelse continue)
            .translated(x, y);
        if (clip) |clip_rect| {
            opaque_rect = opaque_rect.intersection(clip_rect) orelse continue;
        }
        if (!result.append(opaque_rect)) break;
    }
    return result;
}

fn surfaceEffectRect(rectangle: Region.Rectangle, size: render.Size) ?render.Rect {
    return (render.Rect{
        .x = rectangle.x,
        .y = rectangle.y,
        .width = rectangle.width,
        .height = rectangle.height,
    }).clipTo(size);
}

test "background effect rectangles are clipped to the surface" {
    try std.testing.expectEqual(
        render.Rect{ .x = 0, .y = 4, .width = 6, .height = 4 },
        surfaceEffectRect(
            .{ .x = -2, .y = 4, .width = 8, .height = 10 },
            .{ .width = 10, .height = 8 },
        ).?,
    );
    try std.testing.expectEqual(
        @as(?render.Rect, null),
        surfaceEffectRect(
            .{ .x = 10, .y = 0, .width = 1, .height = 1 },
            .{ .width = 10, .height = 8 },
        ),
    );
}

fn renderBufferTransform(transform: wl.Output.Transform) render.BufferTransform {
    return switch (transform) {
        .normal => .normal,
        .@"90" => .rotate_90,
        .@"180" => .rotate_180,
        .@"270" => .rotate_270,
        .flipped => .flipped,
        .flipped_90 => .flipped_90,
        .flipped_180 => .flipped_180,
        .flipped_270 => .flipped_270,
        else => unreachable,
    };
}

fn renderBorders(
    self: *Self,
    frame: *const OutputFrame,
    content_rect: render.Rect,
    borders: ?Scene.Borders,
    corner_radius: u32,
    clip: ?render.Rect,
) Renderer.Error!void {
    const configured = borders orelse return;
    var commands: [4]render.Command = undefined;
    const border_commands = window_geometry.makeBorderCommands(
        content_rect,
        configured,
        corner_radius,
        clip,
        &commands,
    );
    try self.renderCommands(frame, border_commands);
}

fn renderWindowDecorations(
    self: *Self,
    frame: *const OutputFrame,
    window_id: Scene.Id,
    window: *const Scene.Window,
    layer: Scene.DecorationLayer,
    clip: ?render.Rect,
) Renderer.Error!void {
    var decorations = self.scene.decorationIterator(window_id, layer);
    while (decorations.next()) |entry| {
        if (!entry.decoration.mapped) continue;
        try self.renderSurfaceTree(
            frame,
            entry.decoration.surface_id,
            window.position.x +| entry.decoration.offset.x,
            window.position.y +| entry.decoration.offset.y,
            null,
            clip,
        );
    }
}

fn submitSurfaceTree(self: *Self, output: *Output, surface_id: Surface.Id) void {
    if (Surface.currentBuffer(self.compositor.surfaceStore(), surface_id) == null) return;

    var stack = self.subcompositor.stackIterator(surface_id);
    while (stack.next()) |entry| switch (entry) {
        .parent => if (output.containsSurface(surface_id) and
            self.renderer.wasSampled(surfaceSampleTag(surface_id)))
        {
            Surface.submitPresentationFor(self.compositor.surfaceStore(), surface_id, output);
        },
        .child => |child| self.submitSurfaceTree(output, child.surface_id),
    };
}

fn submitCapturedSurfaceTree(self: *Self, output: *Output, surface_id: Surface.Id) void {
    if (Surface.currentBuffer(self.compositor.surfaceStore(), surface_id) == null) return;

    var stack = self.subcompositor.stackIterator(surface_id);
    while (stack.next()) |entry| switch (entry) {
        .parent => if (output.containsSurface(surface_id)) {
            Surface.submitPresentationFor(self.compositor.surfaceStore(), surface_id, output);
        },
        .child => |child| self.submitCapturedSurfaceTree(output, child.surface_id),
    };
}

fn submitWindowDecorations(
    self: *Self,
    output: *Output,
    window_id: Scene.Id,
    layer: Scene.DecorationLayer,
) void {
    var decorations = self.scene.decorationIterator(window_id, layer);
    while (decorations.next()) |entry| {
        if (!entry.decoration.mapped) continue;
        self.submitSurfaceTree(output, entry.decoration.surface_id);
    }
}

fn submitCapturedWindowDecorations(
    self: *Self,
    output: *Output,
    window_id: Scene.Id,
    layer: Scene.DecorationLayer,
) void {
    var decorations = self.scene.decorationIterator(window_id, layer);
    while (decorations.next()) |entry| {
        if (!entry.decoration.mapped) continue;
        self.submitCapturedSurfaceTree(output, entry.decoration.surface_id);
    }
}

fn submitWindowPopups(self: *Self, output: *Output, window_id: Scene.Id) void {
    var popups = self.scene.popupIterator(window_id);
    while (popups.next()) |entry| {
        if (!entry.popup.mapped) continue;
        self.submitSurfaceTree(output, entry.popup.surface_id);
    }
}

test "server creates and destroys protocol globals" {
    const server = try Self.create(std.testing.allocator, std.testing.io, .cpu, .headless, null);
    defer server.destroy();
    try std.testing.expect(!server.native_input_initialized);
    try std.testing.expect(server.input_manager_initialized);
    try std.testing.expect(server.builtin_keybindings_initialized);
    try std.testing.expect(server.window_manager_initialized);
}

test "general configuration maps window shadows" {
    const defaults: Config.GeneralSettings = .{};
    const dark = configuredWindowEffects(defaults, theme.dark);
    try std.testing.expectEqual(Scene.Position{ .y = 4 }, dark.tiled.key_shadow.?.offset);
    try std.testing.expectEqual(@as(u32, 8), dark.tiled.key_shadow.?.blur_radius);
    try std.testing.expectEqual(Scene.Position{ .y = 8 }, dark.tiled_focused.key_shadow.?.offset);
    try std.testing.expectEqual(@as(u32, 16), dark.tiled_focused.key_shadow.?.blur_radius);
    try std.testing.expectEqual(Scene.Position{ .y = 14 }, dark.floating.key_shadow.?.offset);
    try std.testing.expectEqual(@as(u32, 28), dark.floating.key_shadow.?.blur_radius);
    try std.testing.expectEqual(Scene.Position{ .y = 32 }, dark.floating_focused.key_shadow.?.offset);
    try std.testing.expectEqual(@as(u32, 64), dark.floating_focused.key_shadow.?.blur_radius);
    try std.testing.expectEqual(renderColor(theme.dark.shadow_ambient), dark.tiled.ambient_shadow.?.color);
    try std.testing.expectEqual(renderColor(theme.dark.shadow_key), dark.tiled.key_shadow.?.color);

    const light = configuredWindowEffects(defaults, theme.light);
    try std.testing.expectEqual(renderColor(theme.light.shadow_ambient), light.tiled.ambient_shadow.?.color);
    try std.testing.expectEqual(renderColor(theme.light.shadow_key), light.tiled.key_shadow.?.color);

    var configured = defaults;
    configured.shadow_blur_radius = 20;
    configured.shadow_color = .{
        .red = 0x10,
        .green = 0x20,
        .blue = 0x30,
        .alpha = 0x70,
    };
    configured.focused_shadow_color = .{
        .red = 0x7a,
        .green = 0xa2,
        .blue = 0xf7,
        .alpha = 0x80,
    };
    const overridden = configuredWindowEffects(configured, theme.light);
    try std.testing.expectEqual(
        render.Color.rgba(0x7a, 0xa2, 0xf7, 0x80),
        overridden.tiled_focused.key_shadow.?.color,
    );
    try std.testing.expectEqual(
        render.Color.rgba(0x7a, 0xa2, 0xf7, 0x6e),
        overridden.tiled_focused.ambient_shadow.?.color,
    );
    try std.testing.expectEqual(@as(u32, 20), overridden.tiled.key_shadow.?.blur_radius);
    try std.testing.expectEqual(render.Color.rgba(0x10, 0x20, 0x30, 0x70), overridden.floating.key_shadow.?.color);

    var disabled = defaults;
    disabled.shadow_enabled = false;
    const effects = configuredWindowEffects(disabled, theme.dark);
    try std.testing.expect(effects.tiled.ambient_shadow == null);
    try std.testing.expect(effects.tiled.key_shadow == null);
    try std.testing.expectEqual(@as(u32, 12), effects.tiled.corner_radius);
}

test "general configuration maps window borders" {
    const defaults: Config.GeneralSettings = .{};
    const default_unfocused = windowBorder(
        defaults.unfocused_border_width,
        defaults.unfocused_border_color orelse theme.default_palette.unfocused_border,
    ).?;
    try std.testing.expectEqual(@as(u32, 1), default_unfocused.width);
    try std.testing.expectEqual(
        renderColor(theme.default_palette.unfocused_border),
        default_unfocused.color,
    );
    const default_focused = windowBorder(
        defaults.focused_border_width,
        defaults.focused_border_color orelse theme.default_palette.focused_border,
    ).?;
    try std.testing.expectEqual(@as(u32, 2), default_focused.width);
    try std.testing.expectEqual(
        renderColor(theme.default_palette.focused_border),
        default_focused.color,
    );

    try std.testing.expect(windowBorder(
        0,
        defaults.focused_border_color orelse theme.default_palette.focused_border,
    ) == null);

    const configured_color: Config.Color = .{
        .red = 0x7a,
        .green = 0xa2,
        .blue = 0xf7,
        .alpha = 0x80,
    };
    const border = windowBorder(3, configured_color).?;
    try std.testing.expectEqual(@as(u32, 3), border.width);
    try std.testing.expectEqual(
        render.Color.rgba(0x7a, 0xa2, 0xf7, 0x80),
        border.color,
    );
    try std.testing.expect(border.edges.top);
    try std.testing.expect(border.edges.bottom);
    try std.testing.expect(border.edges.left);
    try std.testing.expect(border.edges.right);
}

test "server adds and removes independent render outputs" {
    const server = try Self.create(std.testing.allocator, std.testing.io, .cpu, .headless, null);
    defer server.destroy();

    const second_id = try server.addRenderOutput(std.testing.io, .{
        .kind = .headless,
        .size = .{ .width = 640, .height = 480 },
        .position = .{ .x = 1280 },
        .name = "HEADLESS-2",
        .description = "Keywork test output",
        .model = "headless",
    });
    defer std.debug.assert(server.removeRenderOutput(second_id));

    try std.testing.expectEqual(@as(usize, 2), server.render_outputs.len());
    const second = server.render_outputs.get(second_id).?.*;
    try std.testing.expectEqual(
        Output.Position{ .x = 1280 },
        server.outputs.get(second.protocol_id).?.logicalPosition(),
    );
}

test "pointer motion crosses adjacent outputs and avoids layout gaps" {
    const server = try Self.create(std.testing.allocator, std.testing.io, .cpu, .headless, null);
    defer server.destroy();

    const second_id = try server.addRenderOutput(std.testing.io, .{
        .kind = .headless,
        .size = .{ .width = 640, .height = 480 },
        .position = .{ .x = 1280, .y = 240 },
        .name = "HEADLESS-2",
        .description = "Keywork test output",
        .model = "headless",
    });
    defer std.debug.assert(server.removeRenderOutput(second_id));

    try std.testing.expectEqual(
        RenderOutput.Point{ .x = 1280.25, .y = 300 },
        server.constrainPointerToOutputs(.{ .x = 1280.25, .y = 300 }).?,
    );
    try std.testing.expectEqual(
        RenderOutput.Point{ .x = 1279, .y = 100 },
        server.constrainPointerToOutputs(.{ .x = 1280.25, .y = 100 }).?,
    );
}

test "virtual pointer coordinates respect mapped bounds" {
    try std.testing.expectEqual(
        @as(f64, -100),
        clampVirtualPointerCoordinate(-200, -100, 640),
    );
    try std.testing.expectEqual(
        @as(f64, 539),
        clampVirtualPointerCoordinate(700, -100, 640),
    );
    try std.testing.expectEqual(
        @as(f64, -100),
        normalizedVirtualPointerCoordinate(0, 1000, -100, 640),
    );
    try std.testing.expectEqual(
        @as(f64, 219.5),
        normalizedVirtualPointerCoordinate(500, 1000, -100, 640),
    );
    try std.testing.expectEqual(
        @as(f64, 539),
        normalizedVirtualPointerCoordinate(1200, 1000, -100, 640),
    );
}

test "fullscreen selection is isolated to each output" {
    const server = try Self.create(std.testing.allocator, std.testing.io, .cpu, .headless, null);
    defer server.destroy();

    const first = try server.scene.addWindow(.{ .index = 100, .generation = 1 });
    defer server.scene.removeWindow(first);
    server.scene.setMapped(first, true);
    server.scene.setFullscreen(first, true);
    server.scene.setClipBox(first, .{ .x = 0, .y = 0, .width = 1280, .height = 720 });

    const second = try server.scene.addWindow(.{ .index = 101, .generation = 1 });
    defer server.scene.removeWindow(second);
    server.scene.setPosition(second, .{ .x = 1280 });
    server.scene.setMapped(second, true);
    server.scene.setFullscreen(second, true);
    server.scene.setClipBox(second, .{ .x = 0, .y = 0, .width = 640, .height = 480 });

    try std.testing.expectEqual(first, server.topFullscreenForOutput(.{
        .x = 0,
        .y = 0,
        .width = 1280,
        .height = 720,
    }).?.id);
    try std.testing.expectEqual(second, server.topFullscreenForOutput(.{
        .x = 1280,
        .y = 0,
        .width = 640,
        .height = 480,
    }).?.id);
}
