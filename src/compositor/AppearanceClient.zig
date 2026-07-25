//! Optional client for Prefer's appearance preference stream.
//!
//! The first `WatchAppearance` reply supplies the current color scheme and
//! later replies keep it current. Disconnecting preserves the last valid scheme;
//! the compositor owns fallback behavior when this client cannot be started.

const AppearanceClient = @This();

const std = @import("std");
const varlink = @import("varlink");
const wayland = @import("wayland");
const theme = @import("theme.zig");

const wl = wayland.server.wl;
const log = std.log.scoped(.appearance_client);
const interface_name = "dev.rockorager.Prefer";
const watch_method = interface_name ++ ".WatchAppearance";
const registry_relative_path = "varlink/registry/" ++ interface_name;
const maximum_message_size = 64 * 1024;

allocator: std.mem.Allocator,
fd: std.posix.fd_t,
source: ?*wl.EventSource,
input: std.ArrayList(u8),
output: std.ArrayList(u8),
output_offset: usize,
listener: Listener,

pub const Listener = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque, theme.Scheme) void,
};

const ColorScheme = enum {
    no_preference,
    dark,
    light,
};

const Appearance = struct {
    colorScheme: ColorScheme,
};

const Parameters = struct {
    appearance: Appearance,
};

pub fn init(
    client: *AppearanceClient,
    allocator: std.mem.Allocator,
    io: std.Io,
    event_loop: *wl.EventLoop,
    listener: Listener,
    runtime_directory: []const u8,
) !void {
    if (!std.fs.path.isAbsolute(runtime_directory)) return error.InvalidRuntimeDirectory;
    const path = try std.fs.path.join(
        allocator,
        &.{ runtime_directory, registry_relative_path },
    );
    defer allocator.free(path);

    const address = try std.Io.net.UnixAddress.init(path);
    const stream = try address.connect(io);
    errdefer stream.close(io);
    try setNonblocking(stream.socket.handle);

    client.* = .{
        .allocator = allocator,
        .fd = stream.socket.handle,
        .source = null,
        .input = .empty,
        .output = .empty,
        .output_offset = 0,
        .listener = listener,
    };
    errdefer client.input.deinit(allocator);
    errdefer client.output.deinit(allocator);
    try varlink.encode(allocator, &client.output, .{
        .method = watch_method,
        .parameters = struct {}{},
        .more = true,
    }, maximum_message_size);
    client.source = try event_loop.addFd(
        *AppearanceClient,
        client.fd,
        .{ .writable = true, .hangup = true, .@"error" = true },
        handleEvent,
        client,
    );
    log.info("connected to Prefer appearance stream", .{});
}

pub fn deinit(client: *AppearanceClient) void {
    if (client.source) |source| source.remove();
    if (client.fd >= 0) _ = std.c.close(client.fd);
    client.output.deinit(client.allocator);
    client.input.deinit(client.allocator);
    client.* = undefined;
}

fn handleEvent(_: c_int, mask: wl.EventMask, client: *AppearanceClient) c_int {
    var keep = true;
    if (mask.writable or client.output_offset < client.output.items.len) {
        keep = client.writeAvailable();
    }
    if (keep and mask.readable) keep = client.readAvailable();
    if (keep and (mask.hangup or mask.@"error")) {
        log.info("Prefer appearance stream disconnected", .{});
        keep = false;
    }
    if (!keep) client.disconnect();
    return 0;
}

fn readAvailable(client: *AppearanceClient) bool {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const result = std.c.recv(client.fd, &buffer, buffer.len, 0);
        if (result > 0) {
            const count: usize = @intCast(result);
            if (count > maximum_message_size -| client.input.items.len) {
                log.warn("Prefer appearance reply exceeded the size limit", .{});
                return false;
            }
            client.input.appendSlice(client.allocator, buffer[0..count]) catch |err| {
                log.warn("could not buffer Prefer appearance reply: {t}", .{err});
                return false;
            };
            client.processInput() catch |err| {
                log.warn("invalid Prefer appearance stream: {t}", .{err});
                return false;
            };
            continue;
        }
        if (result == 0) {
            log.info("Prefer appearance stream closed", .{});
            return false;
        }
        switch (std.posix.errno(result)) {
            .AGAIN => return true,
            .INTR => continue,
            else => {
                log.warn("failed to read Prefer appearance stream", .{});
                return false;
            },
        }
    }
}

fn writeAvailable(client: *AppearanceClient) bool {
    while (client.output_offset < client.output.items.len) {
        const pending = client.output.items[client.output_offset..];
        const result = std.c.send(client.fd, pending.ptr, pending.len, std.c.MSG.NOSIGNAL);
        if (result > 0) {
            client.output_offset += @intCast(result);
            continue;
        }
        if (result == 0) return false;
        switch (std.posix.errno(result)) {
            .AGAIN => return true,
            .INTR => continue,
            else => {
                log.warn("failed to start Prefer appearance stream", .{});
                return false;
            },
        }
    }
    client.output.clearRetainingCapacity();
    client.output_offset = 0;
    client.source.?.fdUpdate(.{
        .readable = true,
        .hangup = true,
        .@"error" = true,
    }) catch |err| {
        log.warn("failed to monitor Prefer appearance stream: {t}", .{err});
        return false;
    };
    return true;
}

fn processInput(client: *AppearanceClient) !void {
    var frames: varlink.FrameIterator = .init(client.input.items);
    while (try frames.next()) |message| {
        try processMessage(client.allocator, client.listener, message);
    }
    const consumed = frames.consumed();
    if (consumed == 0) return;
    const remaining = client.input.items[consumed..];
    @memmove(client.input.items[0..remaining.len], remaining);
    client.input.shrinkRetainingCapacity(remaining.len);
}

fn disconnect(client: *AppearanceClient) void {
    if (client.source) |source| source.remove();
    client.source = null;
    if (client.fd >= 0) _ = std.c.close(client.fd);
    client.fd = -1;
}

fn processMessage(
    allocator: std.mem.Allocator,
    listener: Listener,
    message: []const u8,
) !void {
    var reply = try std.json.parseFromSlice(varlink.Reply, allocator, message, .{
        .ignore_unknown_fields = true,
    });
    defer reply.deinit();
    if (reply.value.@"error") |name| {
        log.warn("Prefer rejected appearance subscription: {s}", .{name});
        return error.RemoteError;
    }
    if (!reply.value.continues) return error.UnexpectedStreamEnd;
    var parameters = try std.json.parseFromValue(
        Parameters,
        allocator,
        reply.value.parameters orelse return error.MissingParameters,
        .{ .ignore_unknown_fields = true },
    );
    defer parameters.deinit();
    const preference = parameters.value.appearance.colorScheme;
    const scheme: theme.Scheme = switch (preference) {
        .no_preference => theme.default_scheme,
        .dark => .dark,
        .light => .light,
    };
    listener.changed(listener.context, scheme);
    log.info("applied Prefer color scheme: {t}", .{scheme});
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

test "appearance replies select built-in color schemes" {
    const Capture = struct {
        scheme: ?theme.Scheme = null,

        fn changed(context: *anyopaque, scheme: theme.Scheme) void {
            const capture: *@This() = @ptrCast(@alignCast(context));
            capture.scheme = scheme;
        }
    };
    var capture: Capture = .{};
    try processMessage(std.testing.allocator, .{ .context = &capture, .changed = Capture.changed },
        \\{"parameters":{"appearance":{"colorScheme":"light","accentColor":"#010203","contrast":"no_preference","reducedMotion":"no_preference"}},"continues":true}
    );
    try std.testing.expectEqual(theme.Scheme.light, capture.scheme.?);

    try processMessage(std.testing.allocator, .{ .context = &capture, .changed = Capture.changed },
        \\{"parameters":{"appearance":{"colorScheme":"no_preference","accentColor":null,"contrast":"no_preference","reducedMotion":"no_preference"}},"continues":true}
    );
    try std.testing.expectEqual(theme.default_scheme, capture.scheme.?);
}
