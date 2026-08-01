//! Stable-address owner for the native, headless Wayring compositor slice.
//!
//! Protocol dispatch and SHM completion callbacks only enqueue work.  The
//! EventLoop after-platform phase serializes commits and presentation, which
//! keeps one buffer read active and preserves wire request order.

const NativeServer = @This();

const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const keywork_loop = @import("keywork-loop");
const Server = @import("wayring-server");
const IoUringServer = @import("wayring-server-uring");
const ShmGlobal = @import("ShmGlobal.zig");
const LinuxDmabufGlobal = @import("LinuxDmabufGlobal.zig");
const LinuxDrmSyncobjGlobal = @import("LinuxDrmSyncobjGlobal.zig");
const BufferResource = @import("BufferResource.zig");
const CompositorGlobal = @import("CompositorGlobal.zig");
const OutputGlobal = @import("OutputGlobal.zig");
const SeatGlobal = @import("SeatGlobal.zig");
const FractionalScaleGlobal = @import("FractionalScaleGlobal.zig");
const ViewporterGlobal = @import("ViewporterGlobal.zig");
const XdgShell = @import("XdgShell.zig");
const AsyncShmCopy = @import("AsyncShmCopy.zig");
const shm = @import("shm.zig");
const DrmSyncobj = @import("../drm_syncobj.zig");
const Renderer = @import("../render/Renderer.zig");
const HeadlessOutput = @import("../backend/headless.zig");
const render = @import("../render/types.zig");
const surface_geometry = @import("../surface_geometry.zig");

const EventLoop = keywork_loop.EventLoop;
const IoUringLoop = keywork_loop.IoUringLoop;

allocator: std.mem.Allocator,
io: std.Io,
event_loop: EventLoop,
server: Server,
shm_global: ShmGlobal,
linux_dmabuf_global: LinuxDmabufGlobal,
linux_drm_syncobj_global: LinuxDrmSyncobjGlobal,
compositor_global: CompositorGlobal,
output_global: OutputGlobal,
seat_global: SeatGlobal,
fractional_scale_global: FractionalScaleGlobal,
viewporter_global: ViewporterGlobal,
xdg_shell: XdgShell,
transport: IoUringServer,
renderer: Renderer,
output: HeadlessOutput,
display_name: []u8,
socket_path: [:0]u8,
surfaces: std.ArrayList(*SurfaceState) = .empty,
active: ?ActiveCopy = null,
sync_waits: std.ArrayList(*SyncWait) = .empty,
copy_completed: bool = false,
frame_count: u64 = 0,
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
    listen_backlog: u31 = 128,
};

pub const FrameInspection = struct {
    size: render.Size,
    pixels: []const u32,
    frame_count: u64,
};

const SurfaceState = struct {
    surface: *CompositorGlobal.Surface,
    snapshot: ?shm.Snapshot = null,
    dmabuf: ?DmabufState = null,
    scale: i32 = 1,
    transform: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    full_damage: bool = false,
    viewport: surface_geometry.ViewportState = .{},

    fn deinit(self: *SurfaceState, allocator: std.mem.Allocator) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        if (self.dmabuf) |*dmabuf| dmabuf.deinit(self.surface.client, true);
        self.surface.unreference();
        allocator.destroy(self);
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

const SyncWait = struct {
    event_fd: std.posix.fd_t = -1,
    event_value: u64 = 0,
    handle: ?IoUringLoop.Handle = null,
    completed: bool = false,
    ready: bool = false,
    result: i32 = 0,
    cancel_requested: bool = false,
    commits: std.ArrayList(WaitingCommit) = .empty,
};

const WaitingCommit = struct {
    commit: CompositorGlobal.Commit,
    prepared: bool,
};

const ActiveCopy = struct {
    copy: *AsyncShmCopy,
    commit: CompositorGlobal.Commit,
    state: *SurfaceState,
};

/// Allocates the owner before installing callback contexts, so its address is
/// stable until destroy. The returned server exclusively owns its socket.
pub fn create(allocator: std.mem.Allocator, io: std.Io, options: Options) !*NativeServer {
    const self = try allocator.create(NativeServer);
    errdefer allocator.destroy(self);
    self.allocator = allocator;
    self.io = io;
    self.event_loop = try EventLoop.init(allocator);
    errdefer self.event_loop.deinit();
    self.server = Server.init(allocator);
    errdefer self.server.deinit();
    try self.shm_global.init(allocator, &self.server);
    errdefer self.shm_global.deinit();
    try self.compositor_global.init(allocator, &self.server);
    errdefer self.compositor_global.deinit();
    try self.xdg_shell.init(allocator, &self.server);
    errdefer self.xdg_shell.deinit();
    self.renderer = try Renderer.init(allocator, options.renderer_kind);
    errdefer self.renderer.deinit();
    try self.linux_dmabuf_global.init(allocator, &self.server, self.renderer.dmabufSourceFormats(), self.renderer.dmabufSourceValidator());
    errdefer self.linux_dmabuf_global.deinit();
    try self.linux_drm_syncobj_global.init(
        allocator,
        io,
        &self.server,
        self.renderer.dmabufDeviceId(),
    );
    errdefer self.linux_drm_syncobj_global.deinit();
    self.output = try HeadlessOutput.initForRenderer(
        allocator,
        options.output_size,
        options.scale,
        options.refresh_millihertz,
        self.renderer.offscreenAccess(),
    );
    errdefer self.output.deinit();
    try self.output_global.init(allocator, &self.server, .{
        .mode_size = self.output.size,
        .physical_size = self.output.size,
        .refresh_millihertz = self.output.refreshMillihertz(),
        .scale = self.output.scale.ceil() catch return error.InvalidScale,
        .name = "HEADLESS-1",
        .description = "Keywork headless output",
        .model = "headless",
    });
    errdefer self.output_global.deinit();
    try self.seat_global.init(allocator, &self.server, "default", 0, null);
    errdefer self.seat_global.deinit();
    try self.fractional_scale_global.init(
        allocator,
        &self.server,
        self.output.scale.numerator,
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
    var listener_owned = true;
    errdefer if (listener_owned) {
        _ = linux.close(listener);
        _ = std.c.unlink(selection.path.ptr);
    };
    try self.transport.init(allocator, self.event_loop.ioLoop(), &self.server, listener);
    listener_owned = false;

    self.display_name = selection.name;
    self.socket_path = selection.path;
    self.surfaces = .empty;
    self.active = null;
    self.sync_waits = .empty;
    self.copy_completed = false;
    self.frame_count = 0;
    self.terminating = false;
    self.event_loop.setAfterPlatformHook(self, afterPlatform);
    self.event_loop.setEndTurnHook(self, endTurn);
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
        .size = self.output.size,
        .pixels = self.output.pixels,
        .frame_count = self.frame_count,
    };
}

pub fn pixel(self: *const NativeServer, x: u32, y: u32) u32 {
    return self.output.pixel(x, y);
}

/// Cancels and drains all ring users before freeing callback storage and the
/// EventLoop. This may submit/wait for cancellation CQEs, but never sleeps.
pub fn destroy(self: *NativeServer) void {
    self.terminating = true;
    self.event_loop.clearAfterPlatformHook();
    self.event_loop.clearEndTurnHook();
    if (self.active) |active| active.copy.cancel() catch {};
    for (self.sync_waits.items) |wait| {
        if (wait.handle) |handle| {
            self.event_loop.ioLoop().cancel(handle) catch
                @panic("failed to cancel native DRM syncobj wait");
            wait.cancel_requested = true;
        }
    }
    self.transport.shutdown() catch {};
    while (!self.transport.readyToDeinit() or
        (self.active != null and !self.active.?.copy.isTerminal()) or
        self.hasActiveSyncWait())
    {
        self.event_loop.ioLoop().runOnce() catch @panic("failed to drain native compositor I/O");
        self.transport.dispatch() catch {};
        self.finishCopy(false) catch {};
    }
    self.finishCopy(false) catch {};
    self.transport.dispatch() catch {};
    self.transport.deinit();
    while (self.sync_waits.items.len != 0) self.destroySyncWait(0);
    self.sync_waits.deinit(self.allocator);

    while (self.compositor_global.popCommit()) |commit_value| {
        var commit = commit_value;
        commit.releaseBuffer() catch {};
        commit.deinit();
    }
    for (self.surfaces.items) |state| {
        self.output_global.setSurfaceVisible(state.surface, false) catch {};
        state.deinit(self.allocator);
    }
    self.surfaces.deinit(self.allocator);
    self.viewporter_global.deinit();
    self.fractional_scale_global.deinit();
    self.seat_global.deinit();
    self.output_global.deinit();
    self.xdg_shell.deinit();
    self.compositor_global.deinit();
    self.shm_global.deinit();
    self.linux_drm_syncobj_global.deinit();
    self.linux_dmabuf_global.deinit();
    self.server.deinit();
    self.output.deinit();
    self.renderer.deinit();
    self.event_loop.deinit();
    _ = std.c.unlink(self.socket_path.ptr);
    self.allocator.free(self.socket_path);
    self.allocator.free(self.display_name);
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

fn hasActiveSyncWait(self: *const NativeServer) bool {
    for (self.sync_waits.items) |wait| if (wait.handle != null) return true;
    return false;
}

fn afterPlatform(context: *anyopaque, _: *EventLoop) !void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    try self.transport.dispatch();
    try self.cancelDeadSyncWaits();
    try self.finishCopy(true);
    try self.finishSyncWaits();
    if (self.active == null) try self.applyCommits();
    if (self.pruneSurfaces()) try self.renderScene(null);
}

fn endTurn(context: *anyopaque, _: *EventLoop) !void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    try self.transport.flush();
}

fn applyCommits(self: *NativeServer) !void {
    while (self.active == null) {
        var commit = self.compositor_global.popCommit() orelse return;
        if (self.findSyncWait(commit.surface)) |wait| {
            wait.commits.append(self.allocator, .{ .commit = commit, .prepared = false }) catch {
                commit.releaseBuffer() catch {};
                commit.deinit();
                return error.OutOfMemory;
            };
            continue;
        }
        if (!try self.prepareCommit(&commit)) continue;
        if (commit.synchronization) |synchronization| {
            if (!synchronization.acquire.signaled()) {
                self.startSyncWait(&commit) catch |err| {
                    commit.releaseBuffer() catch {};
                    commit.deinit();
                    return err;
                };
                continue;
            }
        }
        try self.applyCommit(&commit);
    }
}

fn prepareCommit(self: *NativeServer, commit: *CompositorGlobal.Commit) !bool {
    const disposition = self.xdg_shell.handleCommit(commit) catch |err| {
        commit.releaseBuffer() catch {};
        commit.deinit();
        return err;
    };
    if (disposition == .configure_only or commit.surface.client.state != .active) {
        commit.releaseBuffer() catch {};
        commit.deinit();
        return false;
    }
    return true;
}

fn applyCommit(self: *NativeServer, commit: *CompositorGlobal.Commit) !void {
    const state = self.stateFor(commit.surface) catch |err| {
        commit.releaseBuffer() catch {};
        commit.deinit();
        return err;
    };
    state.full_damage = state.full_damage or
        state.scale != commit.scale or
        state.transform != commit.transform or
        state.x != commit.offset_x or
        state.y != commit.offset_y or
        !std.meta.eql(state.viewport, commit.viewport);
    state.scale = commit.scale;
    state.transform = commit.transform;
    state.x = commit.offset_x;
    state.y = commit.offset_y;
    state.viewport = commit.viewport;
    switch (commit.attachment) {
        .buffer => |attachment| {
            if (attachment.buffer.content == .dmabuf) {
                const dmabuf = &attachment.buffer.content.dmabuf;
                _ = surface_geometry.calculate(
                    dmabuf.size,
                    state.scale,
                    @intCast(state.transform),
                    state.viewport,
                    false,
                ) catch |err| {
                    commit.releaseBuffer() catch {};
                    commit.deinit();
                    return self.viewporter_global.postGeometryError(state.surface, err);
                };
                attachment.buffer.reference() catch {
                    commit.releaseBuffer() catch {};
                    commit.deinit();
                    return error.OutOfMemory;
                };
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
                self.output_global.setSurfaceVisible(state.surface, true) catch |err| {
                    commit.deinit();
                    return err;
                };
                const present_result = self.present(commit);
                commit.deinit();
                try present_result;
                return;
            }
            const damage: ?[]const render.Rect = if (commit.buffer_damage.len == 0)
                null
            else
                commit.buffer_damage;
            const reuse = if (state.snapshot) |*snapshot| snapshot else null;
            const copy = AsyncShmCopy.create(
                self.allocator,
                self.event_loop.ioLoop(),
                attachment.buffer.content.shm,
                damage,
                reuse,
                self,
                copyComplete,
            ) catch |err| {
                commit.releaseBuffer() catch {};
                const present_result = self.present(commit);
                commit.deinit();
                try present_result;
                if (err == error.OutOfMemory) return err;
                return;
            };
            self.active = .{ .copy = copy, .commit = commit.*, .state = state };
            copy.start() catch {};
        },
        .removed => {
            if (state.snapshot) |*snapshot| snapshot.deinit();
            state.snapshot = null;
            if (state.dmabuf) |*dmabuf| dmabuf.deinit(state.surface.client, true);
            state.dmabuf = null;
            self.output_global.setSurfaceVisible(state.surface, false) catch |err| {
                commit.deinit();
                return err;
            };
            const present_result = self.present(commit);
            commit.deinit();
            try present_result;
        },
        .unchanged => {
            const size = if (state.dmabuf) |dmabuf|
                dmabuf.buffer.content.dmabuf.size
            else if (state.snapshot) |*snapshot|
                snapshot.size
            else
                null;
            if (size) |buffer_size| {
                _ = surface_geometry.calculate(
                    buffer_size,
                    state.scale,
                    @intCast(state.transform),
                    state.viewport,
                    false,
                ) catch |err| {
                    commit.deinit();
                    return self.viewporter_global.postGeometryError(state.surface, err);
                };
            }
            const present_result = self.present(commit);
            commit.deinit();
            try present_result;
        },
    }
}

fn findSyncWait(self: *const NativeServer, surface: *const CompositorGlobal.Surface) ?*SyncWait {
    for (self.sync_waits.items) |wait| {
        if (wait.commits.items[0].commit.surface == surface) return wait;
    }
    return null;
}

fn startSyncWait(self: *NativeServer, commit: *CompositorGlobal.Commit) !void {
    try self.sync_waits.ensureUnusedCapacity(self.allocator, 1);
    const wait = try self.allocator.create(SyncWait);
    errdefer self.allocator.destroy(wait);
    wait.* = .{};
    errdefer wait.commits.deinit(self.allocator);
    try wait.commits.ensureUnusedCapacity(self.allocator, 1);
    wait.commits.appendAssumeCapacity(.{ .commit = commit.*, .prepared = true });
    errdefer _ = wait.commits.pop();
    try self.armSyncWait(wait);
    self.sync_waits.appendAssumeCapacity(wait);
}

fn armSyncWait(self: *NativeServer, wait: *SyncWait) !void {
    std.debug.assert(wait.handle == null and wait.event_fd < 0);
    std.debug.assert(wait.commits.items.len != 0);
    const synchronization = wait.commits.items[0].commit.synchronization orelse
        return error.MissingSynchronization;
    const event_result = linux.eventfd(0, linux.EFD.CLOEXEC);
    if (std.posix.errno(event_result) != .SUCCESS) return error.SyncWaitFailed;
    wait.event_fd = @intCast(event_result);
    errdefer {
        _ = linux.close(wait.event_fd);
        wait.event_fd = -1;
    }
    if (!synchronization.acquire.armEventFd(wait.event_fd)) return error.SyncWaitFailed;
    wait.event_value = 0;
    wait.completed = false;
    wait.ready = false;
    wait.result = 0;
    wait.cancel_requested = false;
    wait.handle = try self.event_loop.ioLoop().queue(
        wait,
        syncWaitComplete,
        wait,
        prepareSyncWaitRead,
    );
}

fn prepareSyncWaitRead(context: *anyopaque, sqe: *linux.io_uring_sqe) void {
    const wait: *SyncWait = @ptrCast(@alignCast(context));
    sqe.prep_read(wait.event_fd, std.mem.asBytes(&wait.event_value), 0);
}

fn syncWaitComplete(
    context: *anyopaque,
    _: *IoUringLoop,
    completion: IoUringLoop.Completion,
) !void {
    const wait: *SyncWait = @ptrCast(@alignCast(context));
    wait.handle = null;
    wait.result = completion.result;
    wait.completed = true;
}

fn cancelDeadSyncWaits(self: *NativeServer) !void {
    for (self.sync_waits.items) |wait| {
        const surface = wait.commits.items[0].commit.surface;
        if ((surface.client.state == .active and surface.resource_alive) or
            wait.handle == null or wait.cancel_requested) continue;
        try self.event_loop.ioLoop().cancel(wait.handle.?);
        wait.cancel_requested = true;
    }
}

fn finishSyncWaits(self: *NativeServer) !void {
    var index: usize = 0;
    while (index < self.sync_waits.items.len and self.active == null) {
        const wait = self.sync_waits.items[index];
        const surface = wait.commits.items[0].commit.surface;
        if (wait.handle == null and
            (surface.client.state != .active or !surface.resource_alive))
        {
            self.destroySyncWait(index);
            continue;
        }
        if (wait.completed) {
            std.debug.assert(wait.handle == null);
            if (wait.event_fd >= 0) {
                _ = linux.close(wait.event_fd);
                wait.event_fd = -1;
            }
            wait.completed = false;
            if (wait.result != @sizeOf(u64) or wait.event_value == 0) {
                self.destroySyncWait(index);
                continue;
            }
            wait.ready = true;
        }
        if (!wait.ready) {
            index += 1;
            continue;
        }

        while (wait.commits.items.len != 0 and self.active == null) {
            const waiting = &wait.commits.items[0];
            if (!waiting.prepared) {
                const prepared = self.prepareCommit(&waiting.commit) catch |err| {
                    _ = wait.commits.orderedRemove(0);
                    self.destroySyncWait(index);
                    return err;
                };
                if (!prepared) {
                    _ = wait.commits.orderedRemove(0);
                    continue;
                }
                waiting.prepared = true;
            }
            if (waiting.commit.synchronization) |synchronization| {
                if (!synchronization.acquire.signaled()) {
                    self.armSyncWait(wait) catch |err| {
                        self.destroySyncWait(index);
                        return err;
                    };
                    break;
                }
            }
            var ready = wait.commits.orderedRemove(0).commit;
            self.applyCommit(&ready) catch |err| {
                self.destroySyncWait(index);
                return err;
            };
        }
        if (wait.commits.items.len == 0) {
            self.destroySyncWait(index);
            continue;
        }
        index += 1;
    }
}

fn destroySyncWait(self: *NativeServer, index: usize) void {
    const wait = self.sync_waits.swapRemove(index);
    std.debug.assert(wait.handle == null);
    if (wait.event_fd >= 0) _ = linux.close(wait.event_fd);
    for (wait.commits.items) |*waiting| {
        waiting.commit.releaseBuffer() catch {};
        waiting.commit.deinit();
    }
    wait.commits.deinit(self.allocator);
    self.allocator.destroy(wait);
}

fn copyComplete(context: ?*anyopaque, _: *AsyncShmCopy) void {
    const self: *NativeServer = @ptrCast(@alignCast(context.?));
    self.copy_completed = true;
}

fn finishCopy(self: *NativeServer, present_frame: bool) !void {
    if (self.active == null or !self.copy_completed or !self.active.?.copy.isTerminal()) return;
    var active = self.active.?;
    self.active = null;
    self.copy_completed = false;
    var geometry_error: ?surface_geometry.Error = null;
    if (active.copy.takeSnapshot()) |snapshot_value| {
        var snapshot = snapshot_value;
        _ = surface_geometry.calculate(
            snapshot.size,
            active.state.scale,
            @intCast(active.state.transform),
            active.state.viewport,
            false,
        ) catch |err| {
            snapshot.deinit();
            geometry_error = err;
        };
        if (geometry_error == null) {
            if (active.state.snapshot) |*old| old.deinit();
            active.state.snapshot = snapshot;
            if (active.state.dmabuf) |*dmabuf|
                dmabuf.deinit(active.state.surface.client, true);
            active.state.dmabuf = null;
            try self.output_global.setSurfaceVisible(active.state.surface, true);
        } else {
            if (active.state.snapshot) |*old| old.deinit();
            active.state.snapshot = null;
            if (active.state.dmabuf) |*dmabuf|
                dmabuf.deinit(active.state.surface.client, true);
            active.state.dmabuf = null;
            try self.output_global.setSurfaceVisible(active.state.surface, false);
        }
    } else |_| {
        // Invalid mappings and short reads affect only this attachment.
        if (active.state.snapshot) |*old| old.deinit();
        active.state.snapshot = null;
        if (active.state.dmabuf) |*dmabuf|
            dmabuf.deinit(active.state.surface.client, true);
        active.state.dmabuf = null;
        try self.output_global.setSurfaceVisible(active.state.surface, false);
    }
    active.copy.deinit();
    active.commit.releaseBuffer() catch {};
    if (geometry_error) |err| {
        active.commit.deinit();
        return self.viewporter_global.postGeometryError(active.state.surface, err);
    }
    const present_result = if (present_frame) self.present(&active.commit) else {};
    active.commit.deinit();
    try present_result;
}

fn present(self: *NativeServer, commit: *CompositorGlobal.Commit) !void {
    const state = self.findState(commit.surface) orelse return error.SurfaceStateMissing;
    try self.renderScene(state);
    if (commit.surface.client.state != .active) return;
    const now = std.Io.Clock.awake.now(self.io).toMilliseconds();
    try commit.finishFrame(@truncate(@as(u64, @intCast(@max(now, 0)))));
}

fn renderScene(self: *NativeServer, damage_state: ?*SurfaceState) !void {
    var commands: std.ArrayList(render.Command) = .empty;
    defer commands.deinit(self.allocator);
    try commands.append(self.allocator, .{ .clear = render.Color.rgba(0, 0, 0, 0) });
    for (self.surfaces.items) |state| {
        if (!state.surface.resource_alive) continue;
        const pixel_buffer: render.PixelBuffer = if (state.dmabuf) |dmabuf_state| blk: {
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
        const transform = bufferTransform(state.transform);
        const geometry = surface_geometry.calculate(
            pixel_buffer.size,
            state.scale,
            @intCast(state.transform),
            state.viewport,
            false,
        ) catch continue;
        try commands.append(self.allocator, .{ .image = .{
            .x = state.x,
            .y = state.y,
            .size = geometry.logical_size,
            .buffer = pixel_buffer,
            .source = geometry.source,
            .transform = transform,
            .is_opaque = if (pixel_buffer.dmabuf) |source| source.force_opaque else state.snapshot.?.force_opaque,
        } });
    }
    var damage_storage: [1]render.Rect = undefined;
    const damage = if (damage_state) |state| self.frameDamage(state, &damage_storage) else null;
    try self.renderer.beginFrame(self.output.renderTarget(), self.output.scale, .{}, damage, .{});
    try self.renderer.append(commands.items);
    try self.renderer.finishFrame();
    if (damage_state) |state| state.full_damage = false;
    self.frame_count +%= 1;
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
            self.output.scale,
            self.output.size,
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
    const state = try self.allocator.create(SurfaceState);
    errdefer self.allocator.destroy(state);
    try surface.reference();
    errdefer surface.unreference();
    state.* = .{ .surface = surface };
    try self.surfaces.append(self.allocator, state);
    return state;
}

fn findState(self: *const NativeServer, surface: *const CompositorGlobal.Surface) ?*SurfaceState {
    for (self.surfaces.items) |state| if (state.surface == surface) return state;
    return null;
}

fn pruneSurfaces(self: *NativeServer) bool {
    var removed = false;
    var index: usize = 0;
    while (index < self.surfaces.items.len) {
        const state = self.surfaces.items[index];
        const active_state = if (self.active) |active| active.state == state else false;
        if (state.surface.resource_alive or active_state) {
            index += 1;
            continue;
        }
        self.output_global.setSurfaceVisible(state.surface, false) catch {};
        state.deinit(self.allocator);
        _ = self.surfaces.swapRemove(index);
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
