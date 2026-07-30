//! Commands for discovering and controlling hosted Keywork applications.

const std = @import("std");
const control = @import("keywork-application-control");
const varlink = @import("varlink");
const linux = std.os.linux;

const Empty = struct {};

pub const usage =
    \\usage: keyworkctl app COMMAND [INSTANCE | --address ADDRESS]
    \\
    \\commands: list | status | reload
    \\
    \\With no instance, status and reload require exactly one running app.
    \\
;

const Target = union(enum) {
    automatic,
    instance: []const u8,
    address: []const u8,
};

const Command = union(enum) {
    list,
    status: Target,
    reload: Target,
};

pub fn run(init: std.process.Init, arguments: []const []const u8) !void {
    const command = try parse(arguments);
    const runtime_directory = init.environ_map.get("XDG_RUNTIME_DIR") orelse
        return error.MissingRuntimeDirectory;
    return switch (command) {
        .list => list(init, runtime_directory),
        .status => |target| status(init, runtime_directory, target),
        .reload => |target| reload(init, runtime_directory, target),
    };
}

fn list(init: std.process.Init, runtime_directory: []const u8) !void {
    var addresses = try discoverAddresses(init.gpa, init.io, runtime_directory);
    defer deinitAddresses(init.gpa, &addresses);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    defer stdout.interface.flush() catch {};
    for (addresses.items) |address| {
        var reply = callStatus(init.gpa, init.io, address) catch continue;
        defer reply.deinit();
        try printStatus(&stdout.interface, reply.value.status);
    }
}

fn status(init: std.process.Init, runtime_directory: []const u8, target: Target) !void {
    const address = try resolveAddress(init.gpa, init.io, runtime_directory, target);
    defer init.gpa.free(address);
    var reply = try callStatus(init.gpa, init.io, address);
    defer reply.deinit();

    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    defer stdout.interface.flush() catch {};
    try printStatus(&stdout.interface, reply.value.status);
}

fn reload(init: std.process.Init, runtime_directory: []const u8, target: Target) !void {
    const address = try resolveAddress(init.gpa, init.io, runtime_directory, target);
    defer init.gpa.free(address);
    var client = try connect(init.gpa, init.io, address);
    defer client.deinit();
    var reply = try client.call(control.reload_method, Empty{});
    defer reply.deinit();
    try checkRemote(init.io, reply.value);
    const parameters = try std.json.parseFromValue(
        control.ReloadReply,
        init.gpa,
        reply.value.parameters orelse return error.MissingReloadReply,
        .{},
    );
    defer parameters.deinit();

    var buffer: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    defer stdout.interface.flush() catch {};
    try stdout.interface.print("generation {d}\n", .{parameters.value.generation});
}

fn callStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    address: []const u8,
) !std.json.Parsed(control.StatusReply) {
    var client = try connect(allocator, io, address);
    defer client.deinit();
    var reply = try client.call(control.get_status_method, Empty{});
    defer reply.deinit();
    try checkRemote(io, reply.value);
    return std.json.parseFromValue(
        control.StatusReply,
        allocator,
        reply.value.parameters orelse return error.MissingStatusReply,
        .{},
    );
}

fn connect(allocator: std.mem.Allocator, io: std.Io, address: []const u8) !varlink.Client {
    if (!try unixSocketAvailable(address)) return error.ConnectionRefused;
    return varlink.Client.connect(allocator, io, address);
}

fn unixSocketAvailable(address: []const u8) !bool {
    const prefix = "unix:";
    if (!std.mem.startsWith(u8, address, prefix)) return error.UnsupportedAddress;
    const path = address[prefix.len..];
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) {
        return error.InvalidAddress;
    }

    var socket_address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    if (path.len >= socket_address.path.len) return error.PathTooLong;
    @memset(&socket_address.path, 0);
    @memcpy(socket_address.path[0..path.len], path);

    const socket_result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket_result) != .SUCCESS) return error.SocketProbeFailed;
    const fd: i32 = @intCast(socket_result);
    defer _ = linux.close(fd);
    const address_length: linux.socklen_t = @intCast(
        @offsetOf(linux.sockaddr.un, "path") + path.len + 1,
    );
    while (true) switch (linux.errno(linux.connect(fd, @ptrCast(&socket_address), address_length))) {
        .SUCCESS, .ISCONN => return true,
        .INTR => continue,
        .NOENT, .CONNREFUSED => return false,
        .ACCES, .PERM => return error.AccessDenied,
        else => return error.SocketProbeFailed,
    };
}

fn checkRemote(io: std.Io, reply: varlink.Reply) !void {
    if (reply.continues) return error.UnexpectedContinuation;
    const name = reply.@"error" orelse return;
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    if (remoteErrorMessage(name, reply.parameters)) |message| {
        try stderr.interface.print("keyworkctl: {s}\n", .{message});
    } else {
        try stderr.interface.print("keyworkctl: Varlink error: {s}\n", .{name});
    }
    try stderr.interface.flush();
    return error.RemoteError;
}

fn remoteErrorMessage(name: []const u8, parameters: ?std.json.Value) ?[]const u8 {
    if (!std.mem.eql(u8, name, control.reload_failed_error)) return null;
    const value = parameters orelse return null;
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const message = object.get("message") orelse return null;
    return switch (message) {
        .string => |string| string,
        else => null,
    };
}

fn printStatus(writer: *std.Io.Writer, value: control.Status) !void {
    try writer.print("{s}\t{s}\tgeneration {d}", .{
        value.instanceId,
        value.appId,
        value.generation,
    });
    if (value.reloading) try writer.writeAll(" (reloading)");
    try writer.writeByte('\n');
}

fn resolveAddress(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_directory: []const u8,
    target: Target,
) ![]u8 {
    return switch (target) {
        .address => |address| allocator.dupe(u8, address),
        .instance => |instance| instanceAddress(allocator, runtime_directory, instance),
        .automatic => blk: {
            var addresses = try discoverAddresses(allocator, io, runtime_directory);
            defer deinitAddresses(allocator, &addresses);
            var selected: ?[]u8 = null;
            errdefer if (selected) |address| allocator.free(address);
            for (addresses.items) |address| {
                var reply = callStatus(allocator, io, address) catch continue;
                reply.deinit();
                if (selected != null) return error.AmbiguousApplication;
                selected = try allocator.dupe(u8, address);
            }
            break :blk selected orelse return error.NoRunningApplication;
        },
    };
}

fn discoverAddresses(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_directory: []const u8,
) !std.ArrayList([]u8) {
    if (!std.fs.path.isAbsolute(runtime_directory)) return error.InvalidRuntimeDirectory;
    const path = try std.fs.path.join(allocator, &.{ runtime_directory, "keywork", "apps" });
    defer allocator.free(path);
    const dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .empty,
        else => return err,
    };
    defer dir.close(io);

    var addresses: std.ArrayList([]u8) = .empty;
    errdefer deinitAddresses(allocator, &addresses);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .unix_domain_socket and entry.kind != .unknown) continue;
        const address = try instanceAddress(allocator, runtime_directory, entry.name);
        errdefer allocator.free(address);
        try addresses.append(allocator, address);
    }
    return addresses;
}

fn deinitAddresses(allocator: std.mem.Allocator, addresses: *std.ArrayList([]u8)) void {
    for (addresses.items) |address| allocator.free(address);
    addresses.deinit(allocator);
}

fn instanceAddress(allocator: std.mem.Allocator, runtime_directory: []const u8, instance: []const u8) ![]u8 {
    if (instance.len == 0 or std.mem.indexOfScalar(u8, instance, '/') != null) return error.InvalidInstance;
    return std.fmt.allocPrint(
        allocator,
        "unix:{s}/keywork/apps/{s}",
        .{ runtime_directory, instance },
    );
}

fn parse(arguments: []const []const u8) !Command {
    if (arguments.len == 1 and std.mem.eql(u8, arguments[0], "list")) return .list;
    if (arguments.len == 0) return error.InvalidArguments;
    const target: Target = if (arguments.len == 1)
        .automatic
    else if (arguments.len == 2)
        .{ .instance = arguments[1] }
    else if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "--address"))
        .{ .address = arguments[2] }
    else
        return error.InvalidArguments;
    if (std.mem.eql(u8, arguments[0], "status")) return .{ .status = target };
    if (std.mem.eql(u8, arguments[0], "reload")) return .{ .reload = target };
    return error.UnknownCommand;
}

test "application command parsing supports discovery and explicit addresses" {
    try std.testing.expectEqual(Command.list, try parse(&.{"list"}));
    try std.testing.expectEqual(Target.automatic, (try parse(&.{"status"})).status);
    try std.testing.expectEqualStrings("abc", (try parse(&.{ "reload", "abc" })).reload.instance);
    try std.testing.expectEqualStrings(
        "unix:/tmp/app",
        (try parse(&.{ "status", "--address", "unix:/tmp/app" })).status.address,
    );
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "reload", "--address" }));
}

test "application discovery quietly rejects an unavailable socket" {
    try std.testing.expect(!try unixSocketAvailable("unix:/nonexistent/keywork/application.sock"));
    try std.testing.expectError(error.UnsupportedAddress, unixSocketAvailable("tcp:127.0.0.1:1"));
    try std.testing.expectError(error.InvalidAddress, unixSocketAvailable("unix:relative.sock"));
}
