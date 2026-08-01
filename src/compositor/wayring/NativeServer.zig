//! Stable-address owner for the native, headless Wayring compositor slice.
//!
//! Protocol dispatch enqueues transactions. The EventLoop prepares each
//! root's FIFO independently, then atomically applies ready transactions.

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
const SurfaceTree = @import("SurfaceTree.zig");
const SubcompositorGlobal = @import("SubcompositorGlobal.zig");
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
surface_tree: SurfaceTree,
subcompositor_global: SubcompositorGlobal,
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
pending: std.ArrayList(*PendingTransaction) = .empty,
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

const PendingTransaction = struct {
    transaction: CompositorGlobal.Transaction,
    entries: []PendingEntry,
    discarded: bool = false,
};

const PendingEntry = struct {
    prepared: bool = false,
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
    self.surface_tree = SurfaceTree.init(allocator);
    errdefer self.surface_tree.deinit();
    try self.subcompositor_global.init(allocator, &self.server, &self.compositor_global, &self.surface_tree);
    errdefer self.subcompositor_global.deinit();
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
    self.pending = .empty;
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
    self.seat_global.deinit();
    self.output_global.deinit();
    self.xdg_shell.deinit();
    self.subcompositor_global.deinit();
    self.surface_tree.deinit();
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

fn hasPendingIo(self: *const NativeServer) bool {
    for (self.pending.items) |pending| for (pending.entries) |entry|
        if (entry.handle != null or (entry.copy != null and !entry.copy.?.isTerminal())) return true;
    return false;
}

fn afterPlatform(context: *anyopaque, _: *EventLoop) !void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    try self.transport.dispatch();
    try self.intakeTransactions();
    try self.cancelDeadTransactions();
    try self.progressTransactions();
    const pruned = self.pruneSurfaces();
    if (pruned or self.surface_tree.needsRedraw()) try self.renderScene(null);
}

fn endTurn(context: *anyopaque, _: *EventLoop) !void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    try self.transport.flush();
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
    const root = self.pending.items[index].transaction.root;
    for (self.pending.items[0..index]) |earlier|
        if (earlier.transaction.root == root) return false;
    return true;
}

fn prepareCommit(self: *NativeServer, commit: *CompositorGlobal.Commit) !bool {
    const disposition = try self.xdg_shell.handleCommit(commit);
    return disposition != .configure_only and commit.surface.client.state == .active;
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
            if (!entry.prepared) {
                const applicable = self.prepareCommit(commit) catch |err| {
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
                if (commit.attachment == .buffer and commit.attachment.buffer.buffer.content == .shm) {
                    self.startShmCopy(entry, commit) catch |err| {
                        pending.discarded = true;
                        self.cancelPending(pending) catch {};
                        if (pendingIoTerminal(pending)) self.destroyPending(index);
                        return err;
                    };
                }
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
                    continue;
                }
                entry.snapshot = copy.takeSnapshot() catch null;
                entry.copy_failed = entry.snapshot == null;
                copy.deinit();
                entry.copy = null;
            }
            if (entry.handle != null) ready = false;
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
    try self.prepareApplication(pending);
    for (pending.transaction.entries, pending.entries) |*commit, *entry| {
        try self.applyEntry(commit, entry);
    }
    for (pending.transaction.hierarchy_updates) |update| update.apply(update.context);
    const damage_state = if (pending.transaction.entries.len == 1 and
        pending.transaction.hierarchy_updates.len == 0 and
        (self.surface_tree.find(pending.transaction.entries[0].surface) orelse unreachable).parent == null)
        self.findState(pending.transaction.entries[0].surface)
    else
        null;
    try self.renderScene(damage_state);
    const now = std.Io.Clock.awake.now(self.io).toMilliseconds();
    const milliseconds: u32 = @truncate(@as(u64, @intCast(@max(now, 0))));
    for (pending.transaction.entries) |*commit| {
        if (commit.surface.client.state == .active and commit.surface.resource_alive)
            try commit.finishFrame(milliseconds);
    }
}

fn destroyPending(self: *NativeServer, index: usize) void {
    const pending = self.pending.orderedRemove(index);
    std.debug.assert(pendingIoTerminal(pending));
    for (pending.entries) |*entry| {
        if (entry.event_fd >= 0) _ = linux.close(entry.event_fd);
        if (entry.copy) |copy| copy.deinit();
        if (entry.snapshot) |*snapshot| snapshot.deinit();
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
    var commands: std.ArrayList(render.Command) = .empty;
    defer commands.deinit(self.allocator);
    try commands.append(self.allocator, .{ .clear = render.Color.rgba(0, 0, 0, 0) });
    var paint_entries: std.ArrayList(SurfaceTree.PaintEntry) = .empty;
    defer paint_entries.deinit(self.allocator);
    for (self.surfaces.items) |state| {
        const node = self.surface_tree.find(state.surface) orelse continue;
        if (node.parent == null) try self.surface_tree.paint(node, &paint_entries);
    }
    for (paint_entries.items) |paint_entry| {
        const state = self.findState(paint_entry.surface) orelse continue;
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
            .x = paint_entry.x +| state.x,
            .y = paint_entry.y +| state.y,
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
    self.surface_tree.redrawHandled();
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

test "root-head scheduler preserves per-root FIFO and unrelated progress" {
    const root_a: *CompositorGlobal.Surface = @ptrFromInt(0x1000);
    const root_b: *CompositorGlobal.Surface = @ptrFromInt(0x2000);
    var pending_entries: [3][0]PendingEntry = .{ .{}, .{}, .{} };
    var transaction_entries: [3][0]CompositorGlobal.Commit = .{ .{}, .{}, .{} };
    var transactions = [_]PendingTransaction{
        .{ .transaction = .{ .allocator = std.testing.allocator, .root = root_a, .entries = &transaction_entries[0], .hierarchy_updates = &.{} }, .entries = &pending_entries[0] },
        .{ .transaction = .{ .allocator = std.testing.allocator, .root = root_a, .entries = &transaction_entries[1], .hierarchy_updates = &.{} }, .entries = &pending_entries[1] },
        .{ .transaction = .{ .allocator = std.testing.allocator, .root = root_b, .entries = &transaction_entries[2], .hierarchy_updates = &.{} }, .entries = &pending_entries[2] },
    };
    var pointers = [_]*PendingTransaction{ &transactions[0], &transactions[1], &transactions[2] };
    var server: NativeServer = undefined;
    server.pending = .empty;
    server.pending.items = &pointers;

    try std.testing.expect(server.isRootHead(0));
    try std.testing.expect(!server.isRootHead(1));
    try std.testing.expect(server.isRootHead(2));
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
