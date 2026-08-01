//! Stable-address owner for the native, headless Wayring compositor slice.
//!
//! Protocol dispatch and SHM completion callbacks only enqueue work.  The
//! EventLoop after-platform phase serializes commits and presentation, which
//! keeps one buffer read active and preserves wire request order.

const NativeServer = @This();

const std = @import("std");
const linux = std.os.linux;
const keywork_loop = @import("keywork-loop");
const Server = @import("wayring-server");
const IoUringServer = @import("wayring-server-uring");
const ShmGlobal = @import("ShmGlobal.zig");
const CompositorGlobal = @import("CompositorGlobal.zig");
const XdgShell = @import("XdgShell.zig");
const AsyncShmCopy = @import("AsyncShmCopy.zig");
const shm = @import("shm.zig");
const Renderer = @import("../render/Renderer.zig");
const HeadlessOutput = @import("../backend/headless.zig");
const render = @import("../render/types.zig");

const EventLoop = keywork_loop.EventLoop;

allocator: std.mem.Allocator,
io: std.Io,
event_loop: EventLoop,
server: Server,
shm_global: ShmGlobal,
compositor_global: CompositorGlobal,
xdg_shell: XdgShell,
transport: IoUringServer,
renderer: Renderer,
output: HeadlessOutput,
display_name: []u8,
socket_path: [:0]u8,
surfaces: std.ArrayList(*SurfaceState) = .empty,
active: ?ActiveCopy = null,
copy_completed: bool = false,
frame_count: u64 = 0,
terminating: bool = false,

pub const Options = struct {
    /// Used for relative display names. Defaults to XDG_RUNTIME_DIR.
    runtime_directory: ?[]const u8 = null,
    /// A relative Wayland display name, or an absolute socket path.
    display_name: ?[]const u8 = null,
    output_size: render.Size = .{ .width = 1280, .height = 720 },
    scale: render.Scale = .{},
    refresh_millihertz: i32 = 60_000,
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
    scale: i32 = 1,
    transform: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,

    fn deinit(self: *SurfaceState, allocator: std.mem.Allocator) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.surface.unreference();
        allocator.destroy(self);
    }
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
    self.renderer = try Renderer.init(allocator, .cpu);
    errdefer self.renderer.deinit();
    self.output = try HeadlessOutput.initForRenderer(
        allocator,
        options.output_size,
        options.scale,
        options.refresh_millihertz,
        null,
    );
    errdefer self.output.deinit();

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
    try self.event_loop.run();
}

pub fn terminate(self: *NativeServer) void {
    self.event_loop.quit();
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
    self.transport.shutdown() catch {};
    while (!self.transport.readyToDeinit() or
        (self.active != null and !self.active.?.copy.isTerminal()))
    {
        self.event_loop.ioLoop().runOnce() catch @panic("failed to drain native compositor I/O");
        self.transport.dispatch() catch {};
        self.finishCopy(false) catch {};
    }
    self.finishCopy(false) catch {};
    self.transport.dispatch() catch {};
    self.transport.deinit();

    while (self.compositor_global.popCommit()) |commit_value| {
        var commit = commit_value;
        commit.releaseBuffer() catch {};
        commit.deinit();
    }
    for (self.surfaces.items) |state| state.deinit(self.allocator);
    self.surfaces.deinit(self.allocator);
    self.xdg_shell.deinit();
    self.compositor_global.deinit();
    self.shm_global.deinit();
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

fn afterPlatform(context: *anyopaque, _: *EventLoop) !void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    try self.transport.dispatch();
    try self.finishCopy(true);
    if (self.active == null) try self.applyCommits();
    if (self.pruneSurfaces()) try self.renderScene();
}

fn endTurn(context: *anyopaque, _: *EventLoop) !void {
    const self: *NativeServer = @ptrCast(@alignCast(context));
    try self.transport.flush();
}

fn applyCommits(self: *NativeServer) !void {
    while (self.active == null) {
        var commit = self.compositor_global.popCommit() orelse return;
        const disposition = self.xdg_shell.handleCommit(&commit) catch |err| {
            commit.releaseBuffer() catch {};
            commit.deinit();
            return err;
        };
        if (disposition == .configure_only) {
            commit.releaseBuffer() catch {};
            commit.deinit();
            continue;
        }

        const state = try self.stateFor(commit.surface);
        state.scale = commit.scale;
        state.transform = commit.transform;
        state.x = commit.offset_x;
        state.y = commit.offset_y;
        switch (commit.attachment) {
            .buffer => |attachment| {
                const damage: ?[]const render.Rect = if (commit.buffer_damage.len == 0)
                    null
                else
                    commit.buffer_damage;
                const reuse = if (state.snapshot) |*snapshot| snapshot else null;
                const copy = AsyncShmCopy.create(
                    self.allocator,
                    self.event_loop.ioLoop(),
                    attachment.buffer,
                    damage,
                    reuse,
                    self,
                    copyComplete,
                ) catch |err| {
                    commit.releaseBuffer() catch {};
                    const present_result = self.present(&commit);
                    commit.deinit();
                    try present_result;
                    if (err == error.OutOfMemory) return err;
                    continue;
                };
                self.active = .{ .copy = copy, .commit = commit, .state = state };
                copy.start() catch {};
            },
            .removed => {
                if (state.snapshot) |*snapshot| snapshot.deinit();
                state.snapshot = null;
                const present_result = self.present(&commit);
                commit.deinit();
                try present_result;
            },
            .unchanged => {
                const present_result = self.present(&commit);
                commit.deinit();
                try present_result;
            },
        }
    }
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
    if (active.copy.takeSnapshot()) |snapshot| {
        if (active.state.snapshot) |*old| old.deinit();
        active.state.snapshot = snapshot;
    } else |_| {
        // Invalid mappings and short reads affect only this attachment.
        if (active.state.snapshot) |*old| old.deinit();
        active.state.snapshot = null;
    }
    active.copy.deinit();
    active.commit.releaseBuffer() catch {};
    const present_result = if (present_frame) self.present(&active.commit) else {};
    active.commit.deinit();
    try present_result;
}

fn present(self: *NativeServer, commit: *CompositorGlobal.Commit) !void {
    try self.renderScene();
    if (commit.surface.client.state != .active) return;
    const now = std.Io.Clock.awake.now(self.io).toMilliseconds();
    try commit.finishFrame(@truncate(@as(u64, @intCast(@max(now, 0)))));
}

fn renderScene(self: *NativeServer) !void {
    var commands: std.ArrayList(render.Command) = .empty;
    defer commands.deinit(self.allocator);
    try commands.append(self.allocator, .{ .clear = render.Color.rgba(0, 0, 0, 0) });
    for (self.surfaces.items) |state| {
        if (!state.surface.resource_alive) continue;
        const snapshot = if (state.snapshot) |*value| value else continue;
        const transform: render.BufferTransform = switch (state.transform) {
            0 => .normal,
            1 => .rotate_90,
            2 => .rotate_180,
            3 => .rotate_270,
            4 => .flipped,
            5 => .flipped_90,
            6 => .flipped_180,
            7 => .flipped_270,
            else => .normal,
        };
        const transformed = transform.applyToSize(snapshot.size);
        const divisor: u32 = @intCast(@max(state.scale, 1));
        try commands.append(self.allocator, .{ .image = .{
            .x = state.x,
            .y = state.y,
            .size = .{
                .width = @max(transformed.width / divisor, 1),
                .height = @max(transformed.height / divisor, 1),
            },
            .buffer = snapshot.pixelBuffer(),
            .transform = transform,
            .is_opaque = snapshot.force_opaque,
        } });
    }
    try self.renderer.beginFrame(self.output.renderTarget(), self.output.scale, .{}, null, .{});
    try self.renderer.append(commands.items);
    try self.renderer.finishFrame();
    self.frame_count +%= 1;
}

fn stateFor(self: *NativeServer, surface: *CompositorGlobal.Surface) !*SurfaceState {
    for (self.surfaces.items) |state| if (state.surface == surface) return state;
    const state = try self.allocator.create(SurfaceState);
    errdefer self.allocator.destroy(state);
    try surface.reference();
    errdefer surface.unreference();
    state.* = .{ .surface = surface };
    try self.surfaces.append(self.allocator, state);
    return state;
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
    try std.testing.expectEqual(@as(u64, 0), native.inspectFrame().frame_count);
    try std.testing.expectEqual(@as(u32, 0), native.pixel(7, 3));
}
