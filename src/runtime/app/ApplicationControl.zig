//! Process-lifetime Varlink control endpoint for one application instance.

const ApplicationControl = @This();

const std = @import("std");
const protocol = @import("keywork-application-control");
const SystemdEvent = @import("../linux/SystemdEvent.zig");
const systemd = @import("systemd_c");

const log = std.log.scoped(.application_control);
const instance_id_bytes = 12;
const instance_id_length = instance_id_bytes * 2;

pub const ReloadHost = struct {
    ptr: *anyopaque,
    request_fn: *const fn (*anyopaque) anyerror!void,

    pub fn request(self: ReloadHost) !void {
        try self.request_fn(self.ptr);
    }
};

pub const ReloadObserver = struct {
    ptr: *anyopaque,
    completed_fn: *const fn (*anyopaque, bool, []const u8) void,

    pub fn completed(self: ReloadObserver, success: bool, message: []const u8) void {
        self.completed_fn(self.ptr, success, message);
    }
};

allocator: std.mem.Allocator,
io: std.Io,
native: *systemd.sd_varlink_server,
reload_host: ReloadHost,
app_id: [:0]u8,
address: [:0]u8,
instance_id: [instance_id_length:0]u8,
generation: i64 = 1,
reloading: bool = false,
pending: std.ArrayList(*systemd.sd_varlink) = .empty,

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    bridge: *SystemdEvent,
    runtime_directory: []const u8,
    app_id: []const u8,
    reload_host: ReloadHost,
) !*ApplicationControl {
    if (!std.fs.path.isAbsolute(runtime_directory)) return error.InvalidRuntimeDirectory;

    const self = try allocator.create(ApplicationControl);
    errdefer allocator.destroy(self);
    const app_id_z = try allocator.dupeZ(u8, app_id);
    errdefer allocator.free(app_id_z);

    const apps_directory = try std.fs.path.join(allocator, &.{ runtime_directory, "keywork", "apps" });
    defer allocator.free(apps_directory);
    try std.Io.Dir.cwd().createDirPath(io, apps_directory);
    const dir = try std.Io.Dir.openDirAbsolute(io, apps_directory, .{ .iterate = true });
    defer dir.close(io);
    try dir.setPermissions(io, .fromMode(0o700));

    var random: [instance_id_bytes]u8 = undefined;
    std.Io.random(io, &random);
    const encoded_instance_id = std.fmt.bytesToHex(random, .lower);
    var instance_id: [instance_id_length:0]u8 = undefined;
    @memcpy(instance_id[0..], &encoded_instance_id);
    instance_id[instance_id_length] = 0;
    const address = try std.fmt.allocPrintSentinel(
        allocator,
        "unix:{s}/{s}",
        .{ apps_directory, instance_id },
        0,
    );
    errdefer allocator.free(address);

    var native: ?*systemd.sd_varlink_server = null;
    try check(systemd.sd_varlink_server_new(&native, systemd.SD_VARLINK_SERVER_INHERIT_USERDATA));
    errdefer _ = systemd.sd_varlink_server_unref(native.?);

    self.* = .{
        .allocator = allocator,
        .io = io,
        .native = native.?,
        .reload_host = reload_host,
        .app_id = app_id_z,
        .address = address,
        .instance_id = instance_id,
    };
    _ = systemd.sd_varlink_server_set_userdata(self.native, self);
    try check(systemd.sd_varlink_server_set_info(
        self.native,
        "Keywork",
        "Keywork application",
        "1",
        "https://github.com/rockorager/keywork",
    ));
    try check(systemd.sd_varlink_server_add_interface(
        self.native,
        systemd.keywork_application_varlink_interface(),
    ));
    try check(systemd.sd_varlink_server_bind_connect(self.native, connectCallback));
    try check(systemd.sd_varlink_server_bind_method(self.native, protocol.get_status_method, statusCallback));
    try check(systemd.sd_varlink_server_bind_method(self.native, protocol.reload_method, reloadCallback));
    try check(systemd.sd_varlink_server_attach_event(self.native, bridge.sdEvent(), 0));
    errdefer _ = systemd.sd_varlink_server_detach_event(self.native);
    // sd-varlink's server API accepts a filesystem path; `unix:` is the
    // client-facing Varlink service-reference syntax.
    try check(systemd.sd_varlink_server_listen_address(self.native, socketPath(self.address).ptr, 0o600));
    errdefer std.Io.Dir.deleteFileAbsolute(io, socketPath(self.address)) catch {};

    log.info("application control listening at {s}", .{self.address});
    return self;
}

pub fn destroy(self: *ApplicationControl) void {
    while (self.pending.pop()) |link| _ = systemd.sd_varlink_unref(link);
    self.pending.deinit(self.allocator);
    _ = systemd.sd_varlink_server_shutdown(self.native);
    _ = systemd.sd_varlink_server_detach_event(self.native);
    _ = systemd.sd_varlink_server_unref(self.native);
    std.Io.Dir.deleteFileAbsolute(self.io, socketPath(self.address)) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("failed to remove application control socket: {t}", .{err}),
    };
    self.allocator.free(self.address);
    self.allocator.free(self.app_id);
    self.allocator.destroy(self);
}

pub fn observer(self: *ApplicationControl) ReloadObserver {
    return .{ .ptr = self, .completed_fn = reloadCompleted };
}

pub fn controlAddress(self: *const ApplicationControl) []const u8 {
    return self.address;
}

fn socketPath(address: [:0]const u8) [:0]const u8 {
    const prefix = "unix:";
    std.debug.assert(std.mem.startsWith(u8, address, prefix));
    return address[prefix.len.. :0];
}

fn connectCallback(
    _: ?*systemd.sd_varlink_server,
    link_optional: ?*systemd.sd_varlink,
    _: ?*anyopaque,
) callconv(.c) c_int {
    const link = link_optional orelse return -@as(c_int, @intFromEnum(std.posix.E.INVAL));
    var peer_uid: systemd.uid_t = 0;
    if (systemd.sd_varlink_get_peer_uid(link, &peer_uid) < 0 or peer_uid != systemd.geteuid()) {
        return -@as(c_int, @intFromEnum(std.posix.E.PERM));
    }
    return 0;
}

fn statusCallback(
    link_optional: ?*systemd.sd_varlink,
    _: ?*systemd.sd_json_variant,
    _: systemd.sd_varlink_method_flags_t,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const self: *ApplicationControl = @ptrCast(@alignCast(userdata orelse return -1));
    const link = link_optional orelse return -1;
    if (systemd.keywork_application_reply_status(
        link,
        self.app_id.ptr,
        &self.instance_id,
        self.generation,
        @intFromBool(self.reloading),
        1,
    ) < 0) return -1;
    return 1;
}

fn reloadCallback(
    link_optional: ?*systemd.sd_varlink,
    _: ?*systemd.sd_json_variant,
    _: systemd.sd_varlink_method_flags_t,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const self: *ApplicationControl = @ptrCast(@alignCast(userdata orelse return -1));
    const link = link_optional orelse return -1;
    self.pending.ensureUnusedCapacity(self.allocator, 1) catch return -1;
    self.pending.appendAssumeCapacity(systemd.sd_varlink_ref(link).?);
    if (self.reloading) return 1;
    self.reloading = true;
    self.reload_host.request() catch |err| {
        self.complete(false, @errorName(err));
    };
    return 1;
}

fn reloadCompleted(ptr: *anyopaque, success: bool, message: []const u8) void {
    const self: *ApplicationControl = @ptrCast(@alignCast(ptr));
    self.complete(success, message);
}

fn complete(self: *ApplicationControl, success: bool, message: []const u8) void {
    if (success) self.generation += 1;
    self.reloading = false;

    const message_z = if (!success)
        self.allocator.dupeZ(u8, message) catch null
    else
        null;
    defer if (message_z) |value| self.allocator.free(value);
    while (self.pending.pop()) |link| {
        if (success) {
            _ = systemd.keywork_application_reply_reload(link, self.generation);
        } else {
            _ = systemd.keywork_application_error_reload_failed(
                link,
                if (message_z) |value| value.ptr else "reload failed",
            );
        }
        _ = systemd.sd_varlink_unref(link);
    }
}

fn check(result: c_int) !void {
    if (result < 0) {
        log.warn("sd-varlink operation failed with errno {d}", .{-result});
        return error.SystemdVarlinkFailed;
    }
}
