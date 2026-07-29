//! Rootless Xwayland process and display socket lifecycle.

const Self = @This();

const std = @import("std");
const wayland = @import("wayland");
const XwaylandKeyboardGrab = @import("../wayland/xwayland_keyboard_grab.zig");
const XwaylandShell = @import("../wayland/xwayland_shell.zig");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("spawn.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/un.h");
    @cInclude("sys/types.h");
    @cInclude("unistd.h");
});
const wl = wayland.server.wl;
const log = std.log.scoped(.xwayland_server);

const invalid_fd: std.posix.fd_t = -1;
const first_display = 0;
const last_display = 32;
const child_wayland_fd = 3;
const child_wm_fd = 4;
const child_notify_fd = 5;
const child_x_abstract_fd = 6;
const child_x_path_fd = 7;

allocator: std.mem.Allocator,
display: *wl.Server,
event_loop: *wl.EventLoop,
shell: *XwaylandShell,
keyboard_grab: *XwaylandKeyboardGrab,
listener: Listener,
client: ?*wl.Client,
client_destroy_listener: wl.Listener(*wl.Client),
x_sources: [2]?*wl.EventSource,
notify_source: ?*wl.EventSource,
notify_fd: std.posix.fd_t,
notify_buffer: [32]u8,
notify_length: usize,
wm_fd: std.posix.fd_t,
x_fds: [2]std.posix.fd_t,
pid: ?std.posix.pid_t,
ready: bool,
display_number: ?u16,
display_name_buffer: [16:0]u8,
display_name_length: usize,
lock_path_buffer: [64:0]u8,
lock_path_length: usize,
socket_path_buffer: [64:0]u8,
socket_path_length: usize,
lock_owned: bool,
path_socket_owned: bool,
environ_map: ?*std.process.Environ.Map,
previous_display: ?[]u8,

pub const Listener = struct {
    context: *anyopaque,
    /// Takes ownership of wm_fd, including on failure.
    ready: *const fn (*anyopaque, []const u8, std.posix.fd_t) bool,
    stopped: *const fn (*anyopaque) void,
    unavailable: *const fn (*anyopaque) void,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    display: *wl.Server,
    shell: *XwaylandShell,
    keyboard_grab: *XwaylandKeyboardGrab,
    listener: Listener,
) void {
    self.* = .{
        .allocator = allocator,
        .display = display,
        .event_loop = display.getEventLoop(),
        .shell = shell,
        .keyboard_grab = keyboard_grab,
        .listener = listener,
        .client = null,
        .client_destroy_listener = wl.Listener(*wl.Client).init(clientDestroyed),
        .x_sources = .{ null, null },
        .notify_source = null,
        .notify_fd = invalid_fd,
        .notify_buffer = undefined,
        .notify_length = 0,
        .wm_fd = invalid_fd,
        .x_fds = .{ invalid_fd, invalid_fd },
        .pid = null,
        .ready = false,
        .display_number = null,
        .display_name_buffer = undefined,
        .display_name_length = 0,
        .lock_path_buffer = undefined,
        .lock_path_length = 0,
        .socket_path_buffer = undefined,
        .socket_path_length = 0,
        .lock_owned = false,
        .path_socket_owned = false,
        .environ_map = null,
        .previous_display = null,
    };
}

pub fn deinit(self: *Self) void {
    self.stop(false);
    self.* = undefined;
}

pub fn start(
    self: *Self,
    environ_map: *std.process.Environ.Map,
) !void {
    std.debug.assert(self.client == null);
    std.debug.assert(self.display_number == null);
    std.debug.assert(self.environ_map == null);

    try self.openDisplay();
    errdefer self.stop(false);
    self.previous_display = if (environ_map.get("DISPLAY")) |value|
        try self.allocator.dupe(u8, value)
    else
        null;
    self.environ_map = environ_map;
    try environ_map.put("DISPLAY", self.displayName());

    try self.listenForClients();
    log.info("Xwayland will start on demand at {s}", .{self.displayName()});
}

fn listenForClients(self: *Self) !void {
    std.debug.assert(self.display_number != null);
    std.debug.assert(self.client == null);
    std.debug.assert(self.pid == null);
    std.debug.assert(self.x_sources[0] == null and self.x_sources[1] == null);
    errdefer self.stopListening();
    for (self.x_fds, &self.x_sources) |fd, *source| {
        source.* = try self.event_loop.addFd(
            *Self,
            fd,
            .{ .readable = true },
            startOnDemand,
            self,
        );
    }
}

fn stopListening(self: *Self) void {
    for (&self.x_sources) |*source| {
        if (source.*) |event_source| event_source.remove();
        source.* = null;
    }
}

fn startOnDemand(_: std.posix.fd_t, mask: wl.EventMask, self: *Self) c_int {
    if (!mask.readable) {
        if (mask.hangup or mask.@"error") {
            log.err("Xwayland display socket stopped listening", .{});
            self.stop(false);
        }
        return 0;
    }
    self.stopListening();
    self.launch() catch |err| {
        log.err("failed to launch Xwayland: {t}", .{err});
        self.stop(false);
    };
    return 0;
}

fn launch(self: *Self) !void {
    std.debug.assert(self.display_number != null);
    std.debug.assert(self.environ_map != null);
    std.debug.assert(self.client == null);
    std.debug.assert(self.pid == null);

    var wayland_fds = try socketPair();
    defer closeFd(&wayland_fds[1]);
    errdefer closeFd(&wayland_fds[0]);
    var wm_fds = try socketPair();
    defer closeFd(&wm_fds[1]);
    errdefer closeFd(&wm_fds[0]);
    var notify_fds = try pipe();
    defer closeFd(&notify_fds[1]);
    errdefer closeFd(&notify_fds[0]);

    const client = wl.Client.create(self.display, wayland_fds[0]) orelse
        return error.OutOfMemory;
    wayland_fds[0] = invalid_fd;
    self.client = client;
    client.addDestroyListener(&self.client_destroy_listener);
    try self.shell.authorizeClient(client);
    self.keyboard_grab.authorizeClient(client);

    self.wm_fd = wm_fds[0];
    wm_fds[0] = invalid_fd;
    self.notify_fd = notify_fds[0];
    notify_fds[0] = invalid_fd;
    try setNonblocking(self.notify_fd);
    self.notify_source = try self.event_loop.addFd(
        *Self,
        self.notify_fd,
        .{ .readable = true, .hangup = true, .@"error" = true },
        notifyReady,
        self,
    );

    self.pid = try self.spawn(
        self.environ_map.?,
        wayland_fds[1],
        wm_fds[1],
        notify_fds[1],
    );
    log.info("launched Xwayland {s} (pid {d})", .{ self.displayName(), self.pid.? });
}

pub fn displayName(self: *const Self) []const u8 {
    std.debug.assert(self.display_number != null);
    return self.display_name_buffer[0..self.display_name_length];
}

pub fn isReady(self: *const Self) bool {
    return self.ready;
}

pub fn terminate(self: *Self) void {
    const was_running = self.client != null or self.pid != null;
    if (!was_running) return;
    if (self.client) |client| {
        self.client_destroy_listener.link.remove();
        self.client = null;
        client.destroy();
    }
    self.finishProcess();
    self.listener.stopped(self.listener.context);
    self.listenForClients() catch |err| {
        log.err("failed to resume on-demand Xwayland: {t}", .{err});
        self.stop(false);
    };
}

fn spawn(
    self: *Self,
    environ_map: *const std.process.Environ.Map,
    wayland_fd: std.posix.fd_t,
    wm_child_fd: std.posix.fd_t,
    notify_child_fd: std.posix.fd_t,
) !std.posix.pid_t {
    var child_env = try environ_map.clone(self.allocator);
    defer child_env.deinit();
    try child_env.put("WAYLAND_SOCKET", "3");
    const env_block = try child_env.createPosixBlock(self.allocator, .{});
    defer env_block.deinit(self.allocator);

    const display_name_z = self.display_name_buffer[0..self.display_name_length :0];
    const argv = [_:null]?[*:0]const u8{
        "Xwayland",
        display_name_z.ptr,
        "-rootless",
        "-core",
        "-terminate",
        "-listenfd",
        "6",
        "-listenfd",
        "7",
        "-displayfd",
        "5",
        "-wm",
        "4",
    };

    const source_fds = [_]std.posix.fd_t{
        wayland_fd,
        wm_child_fd,
        notify_child_fd,
        self.x_fds[0],
        self.x_fds[1],
    };
    const target_fds = [_]std.posix.fd_t{
        child_wayland_fd,
        child_wm_fd,
        child_notify_fd,
        child_x_abstract_fd,
        child_x_path_fd,
    };
    var inherited_fds: [source_fds.len]std.posix.fd_t = @splat(invalid_fd);
    defer for (&inherited_fds) |*fd| closeFd(fd);
    for (source_fds, &inherited_fds) |source, *inherited| {
        inherited.* = std.c.fcntl(
            source,
            std.posix.F.DUPFD_CLOEXEC,
            @as(c_int, 16),
        );
        if (inherited.* < 0) return error.DuplicateFdFailed;
    }

    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) return error.SpawnActionsFailed;
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    for (inherited_fds, target_fds) |source, target| {
        if (c.posix_spawn_file_actions_adddup2(&actions, source, target) != 0)
            return error.SpawnActionsFailed;
    }
    for (inherited_fds) |fd| {
        if (c.posix_spawn_file_actions_addclose(&actions, fd) != 0)
            return error.SpawnActionsFailed;
    }

    var attributes: c.posix_spawnattr_t = undefined;
    if (c.posix_spawnattr_init(&attributes) != 0) return error.SpawnAttributesFailed;
    defer _ = c.posix_spawnattr_destroy(&attributes);
    var signal_mask: c.sigset_t = undefined;
    if (c.sigemptyset(&signal_mask) != 0 or
        c.posix_spawnattr_setsigmask(&attributes, &signal_mask) != 0 or
        c.posix_spawnattr_setflags(&attributes, c.POSIX_SPAWN_SETSIGMASK) != 0)
    {
        return error.SpawnAttributesFailed;
    }

    var pid: std.posix.pid_t = undefined;
    const result = c.posix_spawnp(
        &pid,
        "Xwayland",
        &actions,
        &attributes,
        @ptrCast(@constCast(&argv)),
        @ptrCast(@constCast(env_block.slice.ptr)),
    );
    if (result != 0) {
        log.err("failed to spawn Xwayland: {s}", .{c.strerror(result)});
        return error.SpawnFailed;
    }
    return pid;
}

fn stop(self: *Self, notify_listener: bool) void {
    const was_running = self.client != null or self.pid != null;
    const was_available = self.display_number != null;
    self.stopListening();
    if (self.client) |client| {
        self.client_destroy_listener.link.remove();
        self.client = null;
        client.destroy();
    }
    self.finishProcess();
    self.closeDisplay();
    self.restoreEnvironment();
    if (was_available) self.listener.unavailable(self.listener.context);
    if (notify_listener and was_running)
        self.listener.stopped(self.listener.context);
}

fn finishProcess(self: *Self) void {
    if (self.notify_source) |source| {
        source.remove();
        self.notify_source = null;
    }
    closeFd(&self.notify_fd);
    closeFd(&self.wm_fd);
    self.notify_length = 0;
    self.pid = null;
    self.ready = false;
}

fn clientDestroyed(listener: *wl.Listener(*wl.Client), client: *wl.Client) void {
    const self: *Self = @fieldParentPtr("client_destroy_listener", listener);
    std.debug.assert(self.client == client);
    listener.link.remove();
    self.client = null;
    if (!self.ready) {
        self.fail("Xwayland exited before becoming ready");
        return;
    }
    self.finishProcess();
    self.listener.stopped(self.listener.context);
    self.listenForClients() catch |err| {
        log.err("failed to resume on-demand Xwayland: {t}", .{err});
        self.stop(false);
    };
}

fn notifyReady(_: std.posix.fd_t, mask: wl.EventMask, self: *Self) c_int {
    if (mask.readable) {
        while (self.notify_length < self.notify_buffer.len) {
            const destination = self.notify_buffer[self.notify_length..];
            const read_length = c.read(self.notify_fd, destination.ptr, destination.len);
            if (read_length > 0) {
                self.notify_length += @intCast(read_length);
                if (std.mem.indexOfScalar(
                    u8,
                    self.notify_buffer[0..self.notify_length],
                    '\n',
                )) |_| {
                    self.markReady() catch self.fail("invalid Xwayland readiness response");
                    return 0;
                }
                continue;
            }
            if (read_length == 0) break;
            switch (std.posix.errno(read_length)) {
                .INTR => continue,
                .AGAIN => break,
                else => {
                    self.fail("failed to read Xwayland readiness response");
                    return 0;
                },
            }
        }
        if (self.notify_length == self.notify_buffer.len) {
            self.fail("Xwayland readiness response is too long");
            return 0;
        }
    }
    if (!self.ready and (mask.hangup or mask.@"error"))
        self.fail("Xwayland exited before becoming ready");
    return 0;
}

fn markReady(self: *Self) !void {
    const newline = std.mem.indexOfScalar(
        u8,
        self.notify_buffer[0..self.notify_length],
        '\n',
    ) orelse return error.IncompleteResponse;
    const reported = std.mem.trim(u8, self.notify_buffer[0..newline], " \t\r");
    const display_number = try std.fmt.parseInt(u16, reported, 10);
    if (display_number != self.display_number.?) return error.UnexpectedDisplay;
    if (self.notify_source) |source| {
        source.remove();
        self.notify_source = null;
    }
    closeFd(&self.notify_fd);
    self.ready = true;
    log.info("Xwayland {s} is ready", .{self.displayName()});
    const wm_fd = self.wm_fd;
    std.debug.assert(wm_fd >= 0);
    self.wm_fd = invalid_fd;
    if (!self.listener.ready(self.listener.context, self.displayName(), wm_fd))
        self.fail("failed to initialize the X window manager");
}

fn fail(self: *Self, message: []const u8) void {
    log.err("{s}", .{message});
    self.stop(true);
}

fn openDisplay(self: *Self) !void {
    try validateSocketDirectory();
    var number: u16 = first_display;
    while (number <= last_display) : (number += 1) {
        if (!self.acquireLock(number)) continue;
        self.display_number = number;
        const display_name = std.fmt.bufPrintZ(
            &self.display_name_buffer,
            ":{d}",
            .{number},
        ) catch unreachable;
        self.display_name_length = display_name.len;
        const socket_path = std.fmt.bufPrintZ(
            &self.socket_path_buffer,
            "/tmp/.X11-unix/X{d}",
            .{number},
        ) catch unreachable;
        self.socket_path_length = socket_path.len;

        self.x_fds[0] = openAbstractSocket(socket_path) catch {
            self.closeDisplay();
            continue;
        };
        self.x_fds[1] = openPathSocket(socket_path) catch {
            self.closeDisplay();
            continue;
        };
        self.path_socket_owned = true;
        return;
    }
    return error.NoXDisplayAvailable;
}

fn acquireLock(self: *Self, number: u16) bool {
    const lock_path = std.fmt.bufPrintZ(
        &self.lock_path_buffer,
        "/tmp/.X{d}-lock",
        .{number},
    ) catch unreachable;
    self.lock_path_length = lock_path.len;
    var retried_stale = false;
    while (true) {
        const fd = std.c.open(
            lock_path.ptr,
            std.c.O{
                .ACCMODE = .WRONLY,
                .CREAT = true,
                .EXCL = true,
                .CLOEXEC = true,
            },
            @as(c.mode_t, 0o444),
        );
        if (fd >= 0) {
            var buffer: [32]u8 = undefined;
            const pid_text = std.fmt.bufPrint(&buffer, "{d: >10}\n", .{std.c.getpid()}) catch
                unreachable;
            if (!writeAll(fd, pid_text)) {
                _ = std.c.close(fd);
                _ = c.unlink(lock_path.ptr);
                return false;
            }
            _ = std.c.close(fd);
            self.lock_owned = true;
            return true;
        }
        if (std.posix.errno(fd) != .EXIST or retried_stale) return false;
        retried_stale = true;
        if (!removeStaleLock(lock_path)) return false;
    }
}

fn closeDisplay(self: *Self) void {
    closeFd(&self.x_fds[0]);
    closeFd(&self.x_fds[1]);
    if (self.path_socket_owned) {
        _ = c.unlink(self.socket_path_buffer[0..self.socket_path_length :0].ptr);
        self.path_socket_owned = false;
    }
    if (self.lock_owned) {
        _ = c.unlink(self.lock_path_buffer[0..self.lock_path_length :0].ptr);
        self.lock_owned = false;
    }
    self.display_number = null;
    self.display_name_length = 0;
    self.lock_path_length = 0;
    self.socket_path_length = 0;
}

fn restoreEnvironment(self: *Self) void {
    const environ_map = self.environ_map orelse return;
    if (self.previous_display) |previous| {
        environ_map.put("DISPLAY", previous) catch
            log.err("failed to restore DISPLAY after Xwayland stopped", .{});
        self.allocator.free(previous);
    } else {
        _ = environ_map.orderedRemove("DISPLAY");
    }
    self.previous_display = null;
    self.environ_map = null;
}

fn validateSocketDirectory() !void {
    var status: c.struct_stat = undefined;
    if (c.stat("/tmp/.X11-unix", &status) < 0) {
        if (std.posix.errno(-1) != .NOENT) return error.InvalidXSocketDirectory;
        if (c.mkdir("/tmp/.X11-unix", 0o1777) < 0 and std.posix.errno(-1) != .EXIST)
            return error.InvalidXSocketDirectory;
        if (c.stat("/tmp/.X11-unix", &status) < 0)
            return error.InvalidXSocketDirectory;
    }
    if (status.st_mode & c.S_IFMT != c.S_IFDIR) return error.InvalidXSocketDirectory;
    const uid = std.c.getuid();
    if (status.st_uid != 0 and status.st_uid != uid) return error.InvalidXSocketDirectory;
    if (status.st_mode & 0o002 != 0 and status.st_mode & c.S_ISVTX == 0)
        return error.InvalidXSocketDirectory;
}

fn removeStaleLock(lock_path: [:0]const u8) bool {
    const fd = std.c.open(lock_path.ptr, std.c.O{
        .CLOEXEC = true,
        .NOFOLLOW = true,
    });
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    var buffer: [32]u8 = undefined;
    const length = c.read(fd, &buffer, buffer.len);
    if (length <= 0) return false;
    const text = std.mem.trim(u8, buffer[0..@intCast(length)], " \t\r\n");
    const pid = std.fmt.parseInt(std.posix.pid_t, text, 10) catch return false;
    if (pid <= 0) return false;
    if (c.kill(pid, 0) == 0 or std.posix.errno(-1) != .SRCH) return false;
    return c.unlink(lock_path.ptr) == 0 or std.posix.errno(-1) == .NOENT;
}

fn openAbstractSocket(path: [:0]const u8) !std.posix.fd_t {
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    if (path.len + 1 > address.sun_path.len) return error.NameTooLong;
    address.sun_path[0] = 0;
    @memcpy(address.sun_path[1..][0..path.len], path);
    const address_length = @offsetOf(c.struct_sockaddr_un, "sun_path") + 1 + path.len;
    if (std.c.bind(fd, @ptrCast(&address), @intCast(address_length)) < 0)
        return error.BindFailed;
    if (c.listen(fd, 128) < 0) return error.ListenFailed;
    return fd;
}

fn openPathSocket(path: [:0]const u8) !std.posix.fd_t {
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    if (path.len + 1 > address.sun_path.len) return error.NameTooLong;
    @memcpy(address.sun_path[0..path.len], path);
    address.sun_path[path.len] = 0;
    _ = c.unlink(path.ptr);
    const address_length = @offsetOf(c.struct_sockaddr_un, "sun_path") + path.len + 1;
    if (std.c.bind(fd, @ptrCast(&address), @intCast(address_length)) < 0)
        return error.BindFailed;
    errdefer _ = c.unlink(path.ptr);
    if (c.chmod(path.ptr, 0o777) < 0) return error.ChmodFailed;
    if (c.listen(fd, 128) < 0) return error.ListenFailed;
    return fd;
}

fn socketPair() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(
        std.c.AF.UNIX,
        std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC,
        0,
        &fds,
    ) < 0) return error.SocketPairFailed;
    return fds;
}

fn pipe() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe2(&fds, .{ .CLOEXEC = true }) < 0) return error.PipeFailed;
    return fds;
}

fn setNonblocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL);
    if (flags < 0) return error.SetNonblockingFailed;
    var status: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
    status.NONBLOCK = true;
    if (std.c.fcntl(
        fd,
        std.posix.F.SETFL,
        @as(c_int, @intCast(@as(u32, @bitCast(status)))),
    ) < 0) return error.SetNonblockingFailed;
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) bool {
    var written: usize = 0;
    while (written < bytes.len) {
        const result = c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (result > 0) {
            written += @intCast(result);
            continue;
        }
        if (result < 0 and std.posix.errno(result) == .INTR) continue;
        return false;
    }
    return true;
}

fn closeFd(fd: *std.posix.fd_t) void {
    if (fd.* < 0) return;
    _ = std.c.close(fd.*);
    fd.* = invalid_fd;
}

test "X display socket names stay within sockaddr_un" {
    var path_buffer: [64:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &path_buffer,
        "/tmp/.X11-unix/X{d}",
        .{last_display},
    );
    const address: c.struct_sockaddr_un = undefined;
    try std.testing.expect(path.len + 1 <= address.sun_path.len);
}
