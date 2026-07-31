//! Varlink ingress for compositor policy commands.

const Self = @This();

const std = @import("std");
const build_options = @import("build-options");
const command = @import("command.zig");
const control = @import("keywork-control");
const varlink = @import("varlink");
const wayland = @import("wayland");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});
const wl = wayland.server.wl;
const log = std.log.scoped(.control);

pub const socket_name = control.socket_name;
pub const interface_name = control.interface_name;

const service_interface_name = varlink.service_interface_name;
const interface_description = control.interface_description;
const service_interface_description = varlink.service_interface_description;
const maximum_message_size = 1024 * 1024;
const maximum_output_size = 1024 * 1024;
const Empty = struct {};

allocator: std.mem.Allocator,
io: std.Io,
event_loop: *wl.EventLoop,
executor: Executor,
address: [:0]u8,
listener: std.Io.net.Server,
listen_source: *wl.EventSource,
clients: std.ArrayList(*Client),

pub const Executor = struct {
    context: *anyopaque,
    execute: *const fn (*anyopaque, command.Command) void,
    /// The returned slice and each window ID are allocated with the supplied
    /// allocator; the control server releases them after encoding the reply.
    windows: *const fn (
        *anyopaque,
        std.mem.Allocator,
    ) anyerror![]control.Window,
    statistics: *const fn (
        *anyopaque,
        std.mem.Allocator,
    ) anyerror!control.PerformanceStatistics,
    reset_statistics: *const fn (*anyopaque) void,
    set_unfocused_border: *const fn (*anyopaque, control.Border) void,
    set_log_level: *const fn (*anyopaque, control.LogLevel) void,
    set_headless_output_mode: *const fn (
        *anyopaque,
        u32,
        u32,
        u32,
    ) control.HeadlessOutputModeResult,
    reload: *const fn (*anyopaque) ?[]const u8,
    quit: *const fn (*anyopaque) void,
};

const Direction = control.Direction;
const WindowTarget = control.WindowTarget;
const Layout = control.Layout;
const LogLevel = control.LogLevel;

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    event_loop: *wl.EventLoop,
    executor: Executor,
    runtime_directory: []const u8,
) !void {
    if (!std.fs.path.isAbsolute(runtime_directory)) return error.InvalidRuntimeDirectory;
    const address = try std.fmt.allocPrintSentinel(
        allocator,
        "unix:{s}/{s}",
        .{ runtime_directory, socket_name },
        0,
    );
    errdefer allocator.free(address);
    const path = socketPath(address);
    const unix_address = try std.Io.net.UnixAddress.init(path);
    var listener = try listen(io, &unix_address, path);
    errdefer listener.deinit(io);
    errdefer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    try setNonblocking(listener.socket.handle);
    if (std.c.chmod(path.ptr, 0o600) < 0) return error.SetSocketPermissionsFailed;
    const listen_source = try event_loop.addFd(
        *Self,
        listener.socket.handle,
        .{ .readable = true, .hangup = true, .@"error" = true },
        handleListenEvent,
        self,
    );
    self.* = .{
        .allocator = allocator,
        .io = io,
        .event_loop = event_loop,
        .executor = executor,
        .address = address,
        .listener = listener,
        .listen_source = listen_source,
        .clients = .empty,
    };
}

pub fn deinit(self: *Self) void {
    self.listen_source.remove();
    while (self.clients.items.len > 0) {
        self.clients.items[self.clients.items.len - 1].destroy();
    }
    self.clients.deinit(self.allocator);
    self.listener.deinit(self.io);
    std.Io.Dir.deleteFileAbsolute(self.io, socketPath(self.address)) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("failed to remove control socket: {t}", .{err}),
    };
    self.allocator.free(self.address);
    self.* = undefined;
}

fn socketPath(address: [:0]const u8) [:0]const u8 {
    const prefix = "unix:";
    std.debug.assert(std.mem.startsWith(u8, address, prefix));
    return address[prefix.len.. :0];
}

fn listen(
    io: std.Io,
    address: *const std.Io.net.UnixAddress,
    path: [:0]const u8,
) !std.Io.net.Server {
    return address.listen(io, .{}) catch |err| {
        if (err != error.AddressInUse) return err;
        if (try socketActive(path)) return err;
        std.Io.Dir.deleteFileAbsolute(io, path) catch |delete_err| switch (delete_err) {
            error.FileNotFound => {},
            else => return delete_err,
        };
        return try address.listen(io, .{});
    };
}

fn socketActive(path: [:0]const u8) !bool {
    if (path.len >= @sizeOf(@FieldType(c.sockaddr_un, "sun_path"))) return error.NameTooLong;
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketProbeFailed;
    defer _ = std.c.close(fd);
    var address = std.mem.zeroes(c.sockaddr_un);
    address.sun_family = c.AF_UNIX;
    @memcpy(address.sun_path[0..path.len], path);
    while (true) {
        const result = c.connect(
            fd,
            .{ .__sockaddr_un__ = &address },
            @sizeOf(c.sockaddr_un),
        );
        if (result == 0) return true;
        switch (std.posix.errno(result)) {
            .CONNREFUSED, .NOENT => return false,
            .INTR => continue,
            else => return error.SocketProbeFailed,
        }
    }
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

fn handleListenEvent(_: c_int, mask: wl.EventMask, self: *Self) c_int {
    if (mask.readable) self.acceptClients();
    if (mask.hangup or mask.@"error") log.warn("control listener reported a socket error", .{});
    return 0;
}

fn acceptClients(self: *Self) void {
    while (true) {
        const fd = c.accept4(
            self.listener.socket.handle,
            .{ .__sockaddr__ = null },
            null,
            c.SOCK_CLOEXEC | c.SOCK_NONBLOCK,
        );
        if (fd < 0) {
            switch (std.posix.errno(fd)) {
                .AGAIN => return,
                .INTR, .CONNABORTED => continue,
                else => log.warn("failed to accept control client", .{}),
            }
            return;
        }
        const peer_uid = peerUid(fd) catch |err| {
            _ = std.c.close(fd);
            log.warn("failed to authenticate control client: {t}", .{err});
            continue;
        };
        if (!peerAuthorized(std.c.geteuid(), peer_uid)) {
            _ = std.c.close(fd);
            log.warn("rejected control client owned by uid {d}", .{peer_uid});
            continue;
        }
        Client.create(self, fd) catch |err| {
            _ = std.c.close(fd);
            log.warn("failed to register control client: {t}", .{err});
        };
    }
}

fn peerUid(fd: std.posix.fd_t) !std.c.uid_t {
    var credentials: c.struct_ucred = undefined;
    var size: c.socklen_t = @sizeOf(c.struct_ucred);
    if (c.getsockopt(
        fd,
        c.SOL_SOCKET,
        c.SO_PEERCRED,
        &credentials,
        &size,
    ) < 0) return error.PeerCredentialsUnavailable;
    if (size != @sizeOf(c.struct_ucred)) return error.InvalidPeerCredentials;
    return credentials.uid;
}

fn peerAuthorized(owner_uid: std.c.uid_t, peer_uid: std.c.uid_t) bool {
    return owner_uid == peer_uid;
}

const Client = struct {
    owner: *Self,
    fd: std.posix.fd_t,
    source: *wl.EventSource,
    input: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    output_offset: usize = 0,
    quit_after_write: bool = false,

    fn create(owner: *Self, fd: std.posix.fd_t) !void {
        const self = try owner.allocator.create(Client);
        errdefer owner.allocator.destroy(self);
        self.* = .{
            .owner = owner,
            .fd = fd,
            .source = undefined,
        };
        self.source = try owner.event_loop.addFd(
            *Client,
            fd,
            .{ .readable = true, .hangup = true, .@"error" = true },
            handleEvent,
            self,
        );
        errdefer self.source.remove();
        try owner.clients.append(owner.allocator, self);
    }

    fn destroy(self: *Client) void {
        const owner = self.owner;
        self.source.remove();
        _ = std.c.close(self.fd);
        for (owner.clients.items, 0..) |client, index| {
            if (client != self) continue;
            _ = owner.clients.swapRemove(index);
            break;
        }
        self.output.deinit(owner.allocator);
        self.input.deinit(owner.allocator);
        owner.allocator.destroy(self);
    }

    fn handleEvent(_: c_int, mask: wl.EventMask, self: *Client) c_int {
        var keep = true;
        if (mask.readable) keep = self.readAvailable();
        if (keep and (mask.writable or self.output_offset < self.output.items.len)) {
            keep = self.writeAvailable();
        }
        if (keep and (mask.hangup or mask.@"error")) keep = false;
        if (!keep) self.destroy();
        return 0;
    }

    fn readAvailable(self: *Client) bool {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const result = std.c.recv(self.fd, &buffer, buffer.len, 0);
            if (result > 0) {
                const count: usize = @intCast(result);
                if (self.input.items.len + count > maximum_message_size) return false;
                self.input.appendSlice(self.owner.allocator, buffer[0..count]) catch return false;
                processInput(
                    self.owner.allocator,
                    self.owner.executor,
                    &self.input,
                    &self.output,
                    &self.quit_after_write,
                ) catch return false;
                if (self.quit_after_write and self.output_offset == self.output.items.len) {
                    self.owner.executor.quit(self.owner.executor.context);
                    return false;
                }
                if (self.output_offset < self.output.items.len) return self.updateMask();
                continue;
            }
            if (result == 0) return false;
            switch (std.posix.errno(result)) {
                .AGAIN => return self.updateMask(),
                .INTR => continue,
                else => return false,
            }
        }
    }

    fn writeAvailable(self: *Client) bool {
        while (true) {
            while (self.output_offset < self.output.items.len) {
                const pending = self.output.items[self.output_offset..];
                const result = std.c.send(self.fd, pending.ptr, pending.len, c.MSG_NOSIGNAL);
                if (result > 0) {
                    self.output_offset += @intCast(result);
                    continue;
                }
                if (result == 0) return false;
                switch (std.posix.errno(result)) {
                    .AGAIN => return self.updateMask(),
                    .INTR => continue,
                    else => return false,
                }
            }
            self.output.clearRetainingCapacity();
            self.output_offset = 0;
            if (self.quit_after_write) {
                self.owner.executor.quit(self.owner.executor.context);
                return false;
            }
            processInput(
                self.owner.allocator,
                self.owner.executor,
                &self.input,
                &self.output,
                &self.quit_after_write,
            ) catch return false;
            if (self.quit_after_write and self.output.items.len == 0) {
                self.owner.executor.quit(self.owner.executor.context);
                return false;
            }
            if (self.output.items.len == 0) return self.updateMask();
        }
    }

    fn updateMask(self: *Client) bool {
        const reply_pending = self.output_offset < self.output.items.len;
        self.source.fdUpdate(.{
            .readable = !reply_pending,
            .writable = reply_pending,
            .hangup = true,
            .@"error" = true,
        }) catch return false;
        return true;
    }
};

fn processInput(
    allocator: std.mem.Allocator,
    executor: Executor,
    input: *std.ArrayList(u8),
    output: *std.ArrayList(u8),
    quit_requested: *bool,
) !void {
    if (output.items.len != 0) return;
    var frames: varlink.FrameIterator = .init(input.items);
    while (try frames.next()) |message| {
        try handleMessage(allocator, executor, message, output, quit_requested);
        if (quit_requested.* or output.items.len != 0) break;
    }
    const consumed = frames.consumed();
    if (consumed == 0) return;
    const remaining = input.items[consumed..];
    @memmove(input.items[0..remaining.len], remaining);
    input.shrinkRetainingCapacity(remaining.len);
}

fn handleMessage(
    allocator: std.mem.Allocator,
    executor: Executor,
    message: []const u8,
    output: *std.ArrayList(u8),
    quit_requested: *bool,
) !void {
    const parsed = try std.json.parseFromSlice(varlink.Call, allocator, message, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const call = parsed.value;
    if (call.upgrade) {
        if (!call.oneway) try writeInvalidParameter(allocator, output, "upgrade");
        return;
    }

    if (std.mem.eql(u8, call.method, service_interface_name ++ ".GetInfo")) {
        if (!emptyParameters(call.parameters)) {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "parameters");
            return;
        }
        if (!call.oneway) try writeMessage(allocator, output, .{ .parameters = .{
            .vendor = "rockorager",
            .product = "Keywork compositor",
            .version = build_options.version,
            .url = "https://github.com/rockorager/keywork",
            .interfaces = [_][]const u8{ service_interface_name, interface_name },
        } });
        return;
    }
    if (std.mem.eql(u8, call.method, service_interface_name ++ ".GetInterfaceDescription")) {
        const parameters = parseParameters(struct { interface: []const u8 }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "interface");
            return;
        };
        defer parameters.deinit();
        const requested = parameters.value.interface;
        const description: ?[]const u8 = if (std.mem.eql(u8, requested, service_interface_name))
            service_interface_description
        else if (std.mem.eql(u8, requested, interface_name))
            interface_description
        else
            null;
        if (description) |value| {
            if (!call.oneway) try writeMessage(allocator, output, .{
                .parameters = .{ .description = value },
            });
        } else if (!call.oneway) {
            try writeMessage(allocator, output, .{
                .@"error" = service_interface_name ++ ".InterfaceNotFound",
                .parameters = .{ .interface = requested },
            });
        }
        return;
    }
    if (std.mem.eql(u8, call.method, control.focus_method)) {
        const parameters = parseParameters(struct { direction: Direction }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "direction");
            return;
        };
        defer parameters.deinit();
        if (!call.oneway) try writeSuccess(allocator, output);
        executor.execute(executor.context, focusCommand(parameters.value.direction));
        return;
    }
    if (std.mem.eql(u8, call.method, control.move_focused_method)) {
        const parameters = parseParameters(struct { direction: Direction }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "direction");
            return;
        };
        defer parameters.deinit();
        if (!call.oneway) try writeSuccess(allocator, output);
        executor.execute(executor.context, moveCommand(parameters.value.direction));
        return;
    }
    if (std.mem.eql(u8, call.method, control.close_method)) {
        const parameters = parseParameters(struct { target: WindowTarget }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "target");
            return;
        };
        defer parameters.deinit();
        if (!call.oneway) try writeSuccess(allocator, output);
        executor.execute(executor.context, .{ .close = switch (parameters.value.target) {
            .focused => .focused,
        } });
        return;
    }
    if (std.mem.eql(u8, call.method, control.toggle_fullscreen_method)) {
        const parameters = parseParameters(struct { target: WindowTarget }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "target");
            return;
        };
        defer parameters.deinit();
        if (!call.oneway) try writeSuccess(allocator, output);
        executor.execute(executor.context, .{ .toggle_fullscreen = switch (parameters.value.target) {
            .focused => .focused,
        } });
        return;
    }
    if (std.mem.eql(u8, call.method, control.toggle_floating_method)) {
        const parameters = parseParameters(struct { target: WindowTarget }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "target");
            return;
        };
        defer parameters.deinit();
        if (!call.oneway) try writeSuccess(allocator, output);
        executor.execute(executor.context, .{ .toggle_floating = switch (parameters.value.target) {
            .focused => .focused,
        } });
        return;
    }
    if (std.mem.eql(u8, call.method, control.set_layout_method)) {
        const parameters = parseParameters(struct { layout: Layout }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "layout");
            return;
        };
        defer parameters.deinit();
        if (!call.oneway) try writeSuccess(allocator, output);
        executor.execute(executor.context, switch (parameters.value.layout) {
            .tiled => .layout_tiled,
        });
        return;
    }
    if (std.mem.eql(u8, call.method, control.switch_workspace_method)) {
        const parameters = parseParameters(struct { workspace: i64 }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "workspace");
            return;
        };
        defer parameters.deinit();
        if (!control.validWorkspace(parameters.value.workspace)) {
            if (!call.oneway) try writeInvalidWorkspace(allocator, output, parameters.value.workspace);
            return;
        }
        if (!call.oneway) try writeSuccess(allocator, output);
        executor.execute(executor.context, .{ .switch_workspace = @intCast(parameters.value.workspace) });
        return;
    }
    if (std.mem.eql(u8, call.method, control.move_focused_to_workspace_method)) {
        const parameters = parseParameters(struct { workspace: i64 }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "workspace");
            return;
        };
        defer parameters.deinit();
        if (!control.validWorkspace(parameters.value.workspace)) {
            if (!call.oneway) try writeInvalidWorkspace(allocator, output, parameters.value.workspace);
            return;
        }
        if (!call.oneway) try writeSuccess(allocator, output);
        executor.execute(executor.context, .{ .move_to_workspace = @intCast(parameters.value.workspace) });
        return;
    }
    if (std.mem.eql(u8, call.method, control.get_windows_method)) {
        if (!emptyParameters(call.parameters)) {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "parameters");
            return;
        }
        const windows = try executor.windows(executor.context, allocator);
        defer {
            for (windows) |window| allocator.free(window.id);
            allocator.free(windows);
        }
        if (!call.oneway) try writeMessage(allocator, output, .{
            .parameters = .{ .windows = windows },
        });
        return;
    }
    if (std.mem.eql(u8, call.method, control.get_performance_statistics_method)) {
        const parameters = parseParameters(struct { reset: bool }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "reset");
            return;
        };
        defer parameters.deinit();
        const statistics = try executor.statistics(executor.context, allocator);
        defer allocator.free(statistics.outputs);
        if (!call.oneway) try writeMessage(allocator, output, .{
            .parameters = statistics,
        });
        if (parameters.value.reset) executor.reset_statistics(executor.context);
        return;
    }
    if (std.mem.eql(u8, call.method, control.set_unfocused_border_method)) {
        const parameters = parseParameters(struct { border: control.Border }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "border");
            return;
        };
        defer parameters.deinit();
        if (!control.validBorder(parameters.value.border)) {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "border");
            return;
        }
        if (!call.oneway) try writeSuccess(allocator, output);
        executor.set_unfocused_border(executor.context, parameters.value.border);
        return;
    }
    if (std.mem.eql(u8, call.method, control.set_log_level_method)) {
        const parameters = parseParameters(struct { level: LogLevel }, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "level");
            return;
        };
        defer parameters.deinit();
        if (!call.oneway) try writeSuccess(allocator, output);
        executor.set_log_level(executor.context, parameters.value.level);
        return;
    }
    if (std.mem.eql(u8, call.method, control.set_headless_output_mode_method)) {
        const Parameters = struct { width: i64, height: i64, scale: i64 };
        const parameters = parseParameters(Parameters, allocator, call.parameters) catch {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "parameters");
            return;
        };
        defer parameters.deinit();
        if (!control.validHeadlessOutputMode(
            parameters.value.width,
            parameters.value.height,
            parameters.value.scale,
        )) {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "mode");
            return;
        }
        const result = executor.set_headless_output_mode(
            executor.context,
            @intCast(parameters.value.width),
            @intCast(parameters.value.height),
            @intCast(parameters.value.scale),
        );
        if (call.oneway) return;
        switch (result) {
            .applied => try writeSuccess(allocator, output),
            .unsupported => try writeEmptyError(
                allocator,
                output,
                control.unsupported_output_backend_error,
            ),
            .failed => try writeEmptyError(
                allocator,
                output,
                control.output_configuration_failed_error,
            ),
        }
        return;
    }
    if (std.mem.eql(u8, call.method, control.reload_configuration_method)) {
        if (!emptyParameters(call.parameters)) {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "parameters");
            return;
        }
        if (executor.reload(executor.context)) |failure_message| {
            if (!call.oneway) try writeConfigurationReloadFailed(allocator, output, failure_message);
            return;
        }
        if (!call.oneway) try writeSuccess(allocator, output);
        return;
    }
    if (std.mem.eql(u8, call.method, control.quit_method)) {
        if (!emptyParameters(call.parameters)) {
            if (!call.oneway) try writeInvalidParameter(allocator, output, "parameters");
            return;
        }
        if (!call.oneway) try writeSuccess(allocator, output);
        quit_requested.* = true;
        return;
    }

    if (!call.oneway) try writeMessage(allocator, output, .{
        .@"error" = service_interface_name ++ ".MethodNotFound",
        .parameters = .{ .method = call.method },
    });
}

fn parseParameters(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
) !std.json.Parsed(T) {
    return std.json.parseFromValue(T, allocator, value orelse return error.MissingField, .{});
}

fn emptyParameters(value: ?std.json.Value) bool {
    const parameters = value orelse return true;
    return switch (parameters) {
        .object => |object| object.count() == 0,
        else => false,
    };
}

fn focusCommand(direction: Direction) command.Command {
    return switch (direction) {
        .next => .focus_next,
        .previous => .focus_previous,
        .left => .{ .focus_direction = .left },
        .down => .{ .focus_direction = .down },
        .up => .{ .focus_direction = .up },
        .right => .{ .focus_direction = .right },
    };
}

fn moveCommand(direction: Direction) command.Command {
    return switch (direction) {
        .next => .move_focused_next,
        .previous => .move_focused_previous,
        .left => .{ .move_focused_direction = .left },
        .down => .{ .move_focused_direction = .down },
        .up => .{ .move_focused_direction = .up },
        .right => .{ .move_focused_direction = .right },
    };
}

fn writeSuccess(allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
    try writeMessage(allocator, output, .{ .parameters = Empty{} });
}

fn writeInvalidParameter(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    parameter: []const u8,
) !void {
    try writeMessage(allocator, output, .{
        .@"error" = service_interface_name ++ ".InvalidParameter",
        .parameters = .{ .parameter = parameter },
    });
}

fn writeInvalidWorkspace(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    workspace: i64,
) !void {
    try writeMessage(allocator, output, .{
        .@"error" = interface_name ++ ".InvalidWorkspace",
        .parameters = .{ .workspace = workspace },
    });
}

fn writeEmptyError(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    name: []const u8,
) !void {
    try writeMessage(allocator, output, .{
        .@"error" = name,
        .parameters = Empty{},
    });
}

fn writeConfigurationReloadFailed(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    message: []const u8,
) !void {
    writeMessage(allocator, output, .{
        .@"error" = control.configuration_reload_failed_error,
        .parameters = .{ .message = message },
    }) catch |err| switch (err) {
        error.OutputTooLarge => try writeMessage(allocator, output, .{
            .@"error" = control.configuration_reload_failed_error,
            .parameters = .{ .message = "configuration error exceeds control reply limit" },
        }),
        else => return err,
    };
}

fn writeMessage(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: anytype,
) !void {
    try varlink.encode(allocator, output, value, maximum_output_size);
}

const Recorder = struct {
    commands: std.ArrayList(command.Command) = .empty,
    windows_count: usize = 0,
    statistics_count: usize = 0,
    statistics_reset_count: usize = 0,
    unfocused_border: ?control.Border = null,
    log_level: ?control.LogLevel = null,
    headless_output_mode: ?struct { width: u32, height: u32, scale: u32 } = null,
    headless_output_mode_result: control.HeadlessOutputModeResult = .applied,
    reload_count: usize = 0,
    reload_failure: ?[]const u8 = null,
    quit_count: usize = 0,

    fn deinit(self: *Recorder) void {
        self.commands.deinit(std.testing.allocator);
    }

    fn executor(self: *Recorder) Executor {
        return .{
            .context = self,
            .execute = execute,
            .windows = windows,
            .statistics = statistics,
            .reset_statistics = resetStatistics,
            .set_unfocused_border = setUnfocusedBorder,
            .set_log_level = setLogLevel,
            .set_headless_output_mode = setHeadlessOutputMode,
            .reload = reload,
            .quit = quit,
        };
    }

    fn execute(context: *anyopaque, value: command.Command) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.commands.append(std.testing.allocator, value) catch unreachable;
    }

    fn windows(
        context: *anyopaque,
        allocator: std.mem.Allocator,
    ) ![]control.Window {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.windows_count += 1;
        const result = try allocator.alloc(control.Window, 1);
        errdefer allocator.free(result);
        result[0] = .{
            .id = try allocator.dupe(u8, "00000001:00000003"),
            .protocol = .xdg_shell,
            .title = "Terminal",
            .appId = "org.example.Terminal",
            .pid = 8124,
            .rect = .{ .x = 16, .y = 16, .width = 1248, .height = 688 },
            .output = "HEADLESS-1",
            .workspace = 1,
            .focused = true,
            .visible = true,
            .floating = false,
            .fullscreen = false,
            .maximized = false,
            .minimized = false,
        };
        return result;
    }

    fn statistics(
        context: *anyopaque,
        allocator: std.mem.Allocator,
    ) !control.PerformanceStatistics {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.statistics_count += 1;
        const result = try allocator.alloc(control.OutputStatistics, 1);
        const latency: control.LatencyStatistics = .{
            .samples = 4,
            .p50Microseconds = 100,
            .p95Microseconds = 200,
            .p99Microseconds = 300,
            .maximumMicroseconds = 400,
        };
        result[0] = .{
            .name = "HEADLESS-1",
            .width = 1280,
            .height = 720,
            .refreshMillihertz = 60_000,
            .lastFrame = .{
                .path = .composited,
                .workingFormat = .rgba16f_linear,
                .scanoutFormat = .none,
                .outputTransform = .normal,
                .damageRectangles = 2,
                .damagedPixels = 20_000,
            },
            .framesRequested = 5,
            .framesStarted = 5,
            .framesPresented = 4,
            .framesDiscarded = 1,
            .acquireRetries = 0,
            .compositedFrames = 3,
            .directScanoutCandidates = 2,
            .directScanoutFrames = 1,
            .directScanoutRejections = .{
                .noFullscreenSurface = 1,
                .nonOpaqueSurface = 0,
                .surfaceTransform = 0,
                .nonDmabuf = 0,
                .yInverted = 0,
                .missingBufferIdentity = 0,
                .colorConversion = 1,
                .unsupportedBackend = 0,
                .outputUnavailable = 0,
                .outputBusy = 0,
                .deviceInactive = 0,
                .unsupportedFormatOrModifier = 0,
                .unsupportedLayout = 0,
                .framebufferImportFailed = 0,
                .pageFlipFailed = 0,
            },
            .overlayScanoutCandidates = 3,
            .overlayScanoutFrames = 2,
            .overlayScanoutRejections = .{
                .noTopmostSurface = 1,
                .nonOpaqueSurface = 0,
                .clippedSurface = 0,
                .transformedSurface = 0,
                .scaledSurface = 0,
                .outsideOutput = 0,
                .nonDmabuf = 0,
                .nonRgbSurface = 0,
                .yInverted = 0,
                .missingBufferIdentity = 0,
                .colorConversion = 0,
                .unsupportedBackend = 0,
                .outputUnavailable = 0,
                .outputBusy = 0,
                .deviceInactive = 0,
                .noOverlayPlane = 0,
                .unsupportedFormatOrModifier = 0,
                .unsupportedLayout = 0,
                .synchronizationFailed = 0,
                .framebufferImportFailed = 0,
                .atomicTestFailed = 0,
                .pageFlipFailed = 0,
            },
            .cpuUploads = 4,
            .dmabufImports = 6,
            .framesOverBudget = 1,
            .gpuExecution = latency,
            .gpuComposition = latency,
            .gpuPreparation = .{ .samples = 4, .p50Microseconds = 101, .p95Microseconds = 201, .p99Microseconds = 301, .maximumMicroseconds = 401 },
            .gpuSolidComposition = .{ .samples = 4, .p50Microseconds = 102, .p95Microseconds = 202, .p99Microseconds = 302, .maximumMicroseconds = 402 },
            .gpuImageComposition = .{ .samples = 4, .p50Microseconds = 103, .p95Microseconds = 203, .p99Microseconds = 303, .maximumMicroseconds = 403 },
            .gpuShadow = .{ .samples = 4, .p50Microseconds = 104, .p95Microseconds = 204, .p99Microseconds = 304, .maximumMicroseconds = 404 },
            .gpuBlurDownsample = .{ .samples = 4, .p50Microseconds = 105, .p95Microseconds = 205, .p99Microseconds = 305, .maximumMicroseconds = 405 },
            .gpuBlurUpsample = .{ .samples = 4, .p50Microseconds = 106, .p95Microseconds = 206, .p99Microseconds = 306, .maximumMicroseconds = 406 },
            .gpuBlurComposite = .{ .samples = 4, .p50Microseconds = 107, .p95Microseconds = 207, .p99Microseconds = 307, .maximumMicroseconds = 407 },
            .gpuCompositionOverhead = .{ .samples = 4, .p50Microseconds = 108, .p95Microseconds = 208, .p99Microseconds = 308, .maximumMicroseconds = 408 },
            .gpuOutputEncode = latency,
            .gpuFrameFinish = .{ .samples = 4, .p50Microseconds = 109, .p95Microseconds = 209, .p99Microseconds = 309, .maximumMicroseconds = 409 },
            .requestToPresentation = latency,
            .requestToRender = latency,
            .renderToCommit = latency,
            .commitToPresentation = latency,
            .renderFenceSamples = 4,
            .renderFencesSignaledBeforeCommit = 2,
            .renderToGpuCompletion = latency,
            .gpuCompletionToPresentation = latency,
        };
        return .{
            .outputs = result,
            .resources = .{ .cachedTextures = 12, .captureBuffers = 2 },
        };
    }

    fn resetStatistics(context: *anyopaque) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.statistics_reset_count += 1;
    }

    fn setUnfocusedBorder(context: *anyopaque, border: control.Border) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.unfocused_border = border;
    }

    fn setLogLevel(context: *anyopaque, level: control.LogLevel) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.log_level = level;
    }

    fn setHeadlessOutputMode(
        context: *anyopaque,
        width: u32,
        height: u32,
        scale: u32,
    ) control.HeadlessOutputModeResult {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.headless_output_mode = .{ .width = width, .height = height, .scale = scale };
        return self.headless_output_mode_result;
    }

    fn reload(context: *anyopaque) ?[]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.reload_count += 1;
        return self.reload_failure;
    }

    fn quit(context: *anyopaque) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.quit_count += 1;
    }
};

test "control socket authenticates the peer uid" {
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0, &sockets),
    );
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);

    const owner_uid = std.c.geteuid();
    try std.testing.expectEqual(owner_uid, try peerUid(sockets[0]));
    try std.testing.expect(peerAuthorized(owner_uid, owner_uid));
    const other_uid = if (owner_uid == std.math.maxInt(std.c.uid_t)) owner_uid - 1 else owner_uid + 1;
    try std.testing.expect(!peerAuthorized(owner_uid, other_uid));
}

test "fragmented and coalesced calls execute one reply at a time in order" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    const focus =
        \\{"method":"dev.rockorager.keywork.compositor.Focus","parameters":{"direction":"left"}}
    ;
    const workspace =
        \\{"method":"dev.rockorager.keywork.compositor.SwitchWorkspace","parameters":{"workspace":3}}
    ;
    const close =
        \\{"method":"dev.rockorager.keywork.compositor.Close","parameters":{"target":"focused"}}
    ;
    try input.appendSlice(std.testing.allocator, focus[0..20]);
    var quit_requested = false;
    try processInput(std.testing.allocator, recorder.executor(), &input, &output, &quit_requested);
    try std.testing.expectEqual(@as(usize, 0), recorder.commands.items.len);
    try input.appendSlice(std.testing.allocator, focus[20..]);
    try input.append(std.testing.allocator, 0);
    try input.appendSlice(std.testing.allocator, workspace);
    try input.append(std.testing.allocator, 0);
    try input.appendSlice(std.testing.allocator, close);
    try input.append(std.testing.allocator, 0);
    try processInput(std.testing.allocator, recorder.executor(), &input, &output, &quit_requested);

    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    try std.testing.expect(std.meta.eql(
        command.Command{ .focus_direction = .left },
        recorder.commands.items[0],
    ));
    try std.testing.expectEqualStrings("{\"parameters\":{}}\x00", output.items);
    try processInput(std.testing.allocator, recorder.executor(), &input, &output, &quit_requested);
    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);

    output.clearRetainingCapacity();
    try processInput(std.testing.allocator, recorder.executor(), &input, &output, &quit_requested);
    try std.testing.expectEqual(@as(usize, 2), recorder.commands.items.len);
    output.clearRetainingCapacity();
    try processInput(std.testing.allocator, recorder.executor(), &input, &output, &quit_requested);

    try std.testing.expectEqual(@as(usize, 3), recorder.commands.items.len);
    try std.testing.expect(std.meta.eql(
        command.Command{ .switch_workspace = 3 },
        recorder.commands.items[1],
    ));
    try std.testing.expect(std.meta.eql(
        command.Command{ .close = .focused },
        recorder.commands.items[2],
    ));
    try std.testing.expectEqualStrings("{\"parameters\":{}}\x00", output.items);
}

test "mutations occur only after their replies fit the output bound" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var quit_requested = false;
    try output.resize(std.testing.allocator, maximum_output_size);

    const focus =
        \\{"method":"dev.rockorager.keywork.compositor.Focus","parameters":{"direction":"left"}}
    ;
    try std.testing.expectError(
        error.OutputTooLarge,
        handleMessage(
            std.testing.allocator,
            recorder.executor(),
            focus,
            &output,
            &quit_requested,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), recorder.commands.items.len);

    const statistics =
        \\{"method":"dev.rockorager.keywork.compositor.GetPerformanceStatistics","parameters":{"reset":true}}
    ;
    try std.testing.expectError(
        error.OutputTooLarge,
        handleMessage(
            std.testing.allocator,
            recorder.executor(),
            statistics,
            &output,
            &quit_requested,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), recorder.statistics_count);
    try std.testing.expectEqual(@as(usize, 0), recorder.statistics_reset_count);

    output.clearRetainingCapacity();
    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        focus,
        &output,
        &quit_requested,
    );
    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
}

test "oneway calls suppress replies and invalid workspaces return typed errors" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var quit_requested = false;

    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"dev.rockorager.keywork.compositor.SetLayout\",\"parameters\":{\"layout\":\"tiled\"},\"oneway\":true}",
        &output,
        &quit_requested,
    );
    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    try std.testing.expectEqual(command.Command.layout_tiled, recorder.commands.items[0]);
    try std.testing.expectEqual(@as(usize, 0), output.items.len);

    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"dev.rockorager.keywork.compositor.SwitchWorkspace\",\"parameters\":{\"workspace\":0}}",
        &output,
        &quit_requested,
    );
    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    try std.testing.expectEqualStrings(
        "{\"error\":\"dev.rockorager.keywork.compositor.InvalidWorkspace\",\"parameters\":{\"workspace\":0}}\x00",
        output.items,
    );
}

test "window state calls execute typed focused-window commands" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var quit_requested = false;

    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"dev.rockorager.keywork.compositor.ToggleFullscreen\",\"parameters\":{\"target\":\"focused\"}}",
        &output,
        &quit_requested,
    );
    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"dev.rockorager.keywork.compositor.ToggleFloating\",\"parameters\":{\"target\":\"focused\"}}",
        &output,
        &quit_requested,
    );

    try std.testing.expectEqual(@as(usize, 2), recorder.commands.items.len);
    try std.testing.expectEqual(
        command.Command{ .toggle_fullscreen = .focused },
        recorder.commands.items[0],
    );
    try std.testing.expectEqual(
        command.Command{ .toggle_floating = .focused },
        recorder.commands.items[1],
    );
    try std.testing.expectEqualStrings(
        "{\"parameters\":{}}\x00{\"parameters\":{}}\x00",
        output.items,
    );
}

test "configuration reload returns success or a typed failure" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var quit_requested = false;

    const call =
        \\{"method":"dev.rockorager.keywork.compositor.ReloadConfiguration","parameters":{}}
    ;
    try handleMessage(std.testing.allocator, recorder.executor(), call, &output, &quit_requested);
    try std.testing.expectEqual(@as(usize, 1), recorder.reload_count);
    try std.testing.expectEqualStrings("{\"parameters\":{}}\x00", output.items);

    output.clearRetainingCapacity();
    recorder.reload_failure = "/home/test/.config/keywork/config:3: unknown general setting";
    try handleMessage(std.testing.allocator, recorder.executor(), call, &output, &quit_requested);
    try std.testing.expectEqual(@as(usize, 2), recorder.reload_count);
    try std.testing.expectEqualStrings(
        "{\"error\":\"dev.rockorager.keywork.compositor.ConfigurationReloadFailed\",\"parameters\":{\"message\":\"/home/test/.config/keywork/config:3: unknown general setting\"}}\x00",
        output.items,
    );
}

test "log level calls forward the typed level" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var quit_requested = false;

    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"dev.rockorager.keywork.compositor.SetLogLevel\",\"parameters\":{\"level\":\"debug\"}}",
        &output,
        &quit_requested,
    );
    try std.testing.expectEqual(control.LogLevel.debug, recorder.log_level.?);
    try std.testing.expectEqualStrings("{\"parameters\":{}}\x00", output.items);
}

test "headless output mode calls validate and return typed results" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var quit_requested = false;
    const call =
        \\{"method":"dev.rockorager.keywork.compositor.SetHeadlessOutputMode","parameters":{"width":1920,"height":1080,"scale":180}}
    ;

    try handleMessage(std.testing.allocator, recorder.executor(), call, &output, &quit_requested);
    const mode = recorder.headless_output_mode.?;
    try std.testing.expectEqual(@as(u32, 1920), mode.width);
    try std.testing.expectEqual(@as(u32, 1080), mode.height);
    try std.testing.expectEqual(@as(u32, 180), mode.scale);
    try std.testing.expectEqualStrings("{\"parameters\":{}}\x00", output.items);

    output.clearRetainingCapacity();
    recorder.headless_output_mode_result = .unsupported;
    try handleMessage(std.testing.allocator, recorder.executor(), call, &output, &quit_requested);
    try std.testing.expectEqualStrings(
        "{\"error\":\"dev.rockorager.keywork.compositor.UnsupportedOutputBackend\",\"parameters\":{}}\x00",
        output.items,
    );

    output.clearRetainingCapacity();
    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"dev.rockorager.keywork.compositor.SetHeadlessOutputMode\",\"parameters\":{\"width\":0,\"height\":1080,\"scale\":180}}",
        &output,
        &quit_requested,
    );
    try std.testing.expectEqualStrings(
        "{\"error\":\"org.varlink.service.InvalidParameter\",\"parameters\":{\"parameter\":\"mode\"}}\x00",
        output.items,
    );
}

test "unfocused border calls validate and forward the typed border" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var quit_requested = false;

    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"dev.rockorager.keywork.compositor.SetUnfocusedBorder\",\"parameters\":{\"border\":{\"width\":2,\"color\":{\"red\":58,\"green\":58,\"blue\":64,\"alpha\":255}}}}",
        &output,
        &quit_requested,
    );
    try std.testing.expectEqual(control.Border{
        .width = 2,
        .color = .{ .red = 58, .green = 58, .blue = 64, .alpha = 255 },
    }, recorder.unfocused_border.?);
    try std.testing.expectEqualStrings("{\"parameters\":{}}\x00", output.items);

    output.clearRetainingCapacity();
    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"dev.rockorager.keywork.compositor.SetUnfocusedBorder\",\"parameters\":{\"border\":{\"width\":257,\"color\":{\"red\":58,\"green\":58,\"blue\":64,\"alpha\":255}}}}",
        &output,
        &quit_requested,
    );
    try std.testing.expectEqualStrings(
        "{\"error\":\"org.varlink.service.InvalidParameter\",\"parameters\":{\"parameter\":\"border\"}}\x00",
        output.items,
    );
}

test "performance statistics return typed output snapshots and forward reset" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var quit_requested = false;

    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"dev.rockorager.keywork.compositor.GetPerformanceStatistics\",\"parameters\":{\"reset\":true}}",
        &output,
        &quit_requested,
    );
    try std.testing.expectEqual(@as(usize, 1), recorder.statistics_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.statistics_reset_count);
    const parsed = try std.json.parseFromSlice(
        struct { parameters: control.PerformanceStatistics },
        std.testing.allocator,
        output.items[0 .. output.items.len - 1],
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.parameters.outputs.len);
    const statistics = parsed.value.parameters.outputs[0];
    try std.testing.expectEqualStrings("HEADLESS-1", statistics.name);
    try std.testing.expectEqual(@as(i64, 4), statistics.framesPresented);
    try std.testing.expectEqual(control.FramePath.composited, statistics.lastFrame.path);
    try std.testing.expectEqual(@as(i64, 20_000), statistics.lastFrame.damagedPixels);
    try std.testing.expectEqual(@as(i64, 3), statistics.overlayScanoutCandidates);
    try std.testing.expectEqual(@as(i64, 2), statistics.overlayScanoutFrames);
    try std.testing.expectEqual(@as(i64, 1), statistics.overlayScanoutRejections.noTopmostSurface);
    try std.testing.expectEqual(@as(i64, 301), statistics.gpuPreparation.p99Microseconds);
    try std.testing.expectEqual(@as(i64, 302), statistics.gpuSolidComposition.p99Microseconds);
    try std.testing.expectEqual(@as(i64, 303), statistics.gpuImageComposition.p99Microseconds);
    try std.testing.expectEqual(@as(i64, 304), statistics.gpuShadow.p99Microseconds);
    try std.testing.expectEqual(@as(i64, 305), statistics.gpuBlurDownsample.p99Microseconds);
    try std.testing.expectEqual(@as(i64, 306), statistics.gpuBlurUpsample.p99Microseconds);
    try std.testing.expectEqual(@as(i64, 307), statistics.gpuBlurComposite.p99Microseconds);
    try std.testing.expectEqual(@as(i64, 308), statistics.gpuCompositionOverhead.p99Microseconds);
    try std.testing.expectEqual(@as(i64, 309), statistics.gpuFrameFinish.p99Microseconds);
    try std.testing.expectEqual(@as(i64, 300), statistics.requestToPresentation.p99Microseconds);
    try std.testing.expectEqual(@as(i64, 4), statistics.renderFenceSamples);
    try std.testing.expectEqual(@as(i64, 2), statistics.renderFencesSignaledBeforeCommit);
    try std.testing.expectEqual(@as(i64, 300), statistics.renderToGpuCompletion.p99Microseconds);
    try std.testing.expectEqual(@as(i64, 300), statistics.gpuCompletionToPresentation.p99Microseconds);
}

test "window query returns typed mapped-window snapshots" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var quit_requested = false;

    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"dev.rockorager.keywork.compositor.GetWindows\",\"parameters\":{}}",
        &output,
        &quit_requested,
    );
    try std.testing.expectEqual(@as(usize, 1), recorder.windows_count);
    const parsed = try std.json.parseFromSlice(
        struct { parameters: struct { windows: []control.Window } },
        std.testing.allocator,
        output.items[0 .. output.items.len - 1],
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.parameters.windows.len);
    const window = parsed.value.parameters.windows[0];
    try std.testing.expectEqualStrings("00000001:00000003", window.id);
    try std.testing.expectEqual(control.WindowProtocol.xdg_shell, window.protocol);
    try std.testing.expectEqualStrings("org.example.Terminal", window.appId.?);
    try std.testing.expectEqualStrings("Terminal", window.title.?);
    try std.testing.expectEqual(@as(?i64, 8124), window.pid);
    try std.testing.expectEqual(control.Rectangle{
        .x = 16,
        .y = 16,
        .width = 1248,
        .height = 688,
    }, window.rect.?);
    try std.testing.expectEqualStrings("HEADLESS-1", window.output);
    try std.testing.expect(window.focused);
    try std.testing.expect(window.visible);
    try std.testing.expect(!window.floating);
}

test "standard service introspection returns the control interface" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var quit_requested = false;

    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"org.varlink.service.GetInterfaceDescription\",\"parameters\":{\"interface\":\"dev.rockorager.keywork.compositor\"}}",
        &output,
        &quit_requested,
    );
    const parsed = try std.json.parseFromSlice(
        struct { parameters: struct { description: []const u8 } },
        std.testing.allocator,
        output.items[0 .. output.items.len - 1],
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(interface_description, parsed.value.parameters.description);
}

test "quit is deferred until the caller's reply can be written" {
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var quit_requested = false;

    try handleMessage(
        std.testing.allocator,
        recorder.executor(),
        "{\"method\":\"dev.rockorager.keywork.compositor.Quit\",\"parameters\":{}}",
        &output,
        &quit_requested,
    );
    try std.testing.expect(quit_requested);
    try std.testing.expectEqual(@as(usize, 0), recorder.quit_count);
    try std.testing.expectEqualStrings("{\"parameters\":{}}\x00", output.items);
}
