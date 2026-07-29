//! systemd readiness and desktop activation environment publication.

const Self = @This();

const std = @import("std");

const c = @cImport({
    @cInclude("systemd/sd-daemon.h");
});
const log = std.log.scoped(.systemd);

const current_desktop = "XDG_CURRENT_DESKTOP=keywork";
const session_desktop = "XDG_SESSION_DESKTOP=keywork";
const session_type = "XDG_SESSION_TYPE=wayland";
const max_assignments = 5;
const environment_names = [_][]const u8{
    "WAYLAND_DISPLAY",
    "DISPLAY",
    // Legacy cleanup only; Keywork no longer publishes or reads this variable.
    "KEYWORK_CONTROL",
    "XDG_CURRENT_DESKTOP",
    "XDG_SESSION_DESKTOP",
    "XDG_SESSION_TYPE",
    "XCURSOR_SIZE",
};

io: std.Io,
environ_map: *const std.process.Environ.Map,
notify_enabled: bool,
session_enabled: bool,

pub fn init(
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    session_enabled: bool,
) Self {
    const notify_enabled = environ_map.get("NOTIFY_SOCKET") != null;
    return .{
        .io = io,
        .environ_map = environ_map,
        .notify_enabled = notify_enabled,
        .session_enabled = session_enabled,
    };
}

pub fn prepare(self: *const Self) !void {
    if (!self.session_enabled or self.notify_enabled) return;

    if (!try self.run(&.{
        "systemctl",
        "--user",
        "stop",
        "keywork-session.target",
        "graphical-session.target",
    })) return error.StaleSessionStopFailed;
    if (!try self.run(&.{ "systemctl", "--user", "reset-failed" })) {
        return error.SystemdResetFailed;
    }
    self.clearActivationEnvironment();
}

pub fn ready(
    self: *const Self,
    wayland_display: []const u8,
    cursor_size: []const u8,
) !void {
    if (self.session_enabled) {
        var display_buffer: [64]u8 = undefined;
        const display = try std.fmt.bufPrint(
            &display_buffer,
            "WAYLAND_DISPLAY={s}",
            .{wayland_display},
        );
        var cursor_size_buffer: [64]u8 = undefined;
        const cursor_size_assignment = try std.fmt.bufPrint(
            &cursor_size_buffer,
            "XCURSOR_SIZE={s}",
            .{cursor_size},
        );
        try self.updateActivationEnvironment(&.{
            display,
            current_desktop,
            session_desktop,
            session_type,
            cursor_size_assignment,
        });
    }

    // Notify an external manager before starting targets which may be ordered
    // after its compositor unit. This avoids waiting on our own readiness.
    if (self.notify_enabled) {
        const notified = c.sd_notify(0, "READY=1");
        if (notified <= 0) return error.NotifyFailed;
    }
    // Session services connect to Wayland, so they cannot become ready until
    // the compositor enters its event loop. Desktop autostart is a separate
    // job so its gate can wait for keywork-shell's status notifier host after
    // the session target itself becomes active.
    if (self.session_enabled and !try self.run(&.{
        "systemctl",
        "--user",
        "--no-block",
        "start",
        "keywork-session.target",
        "keywork-xdg-autostart.service",
    })) return error.SessionTargetStartFailed;
}

pub fn publishDisplay(self: *const Self, display_name: []const u8) !void {
    if (!self.session_enabled) return;

    var display_buffer: [32]u8 = undefined;
    const display = try std.fmt.bufPrint(
        &display_buffer,
        "DISPLAY={s}",
        .{display_name},
    );
    try self.updateActivationEnvironment(&.{display});
}

pub fn unpublishDisplay(self: *const Self) !void {
    if (!self.session_enabled) return;

    if (!try self.run(&.{ "systemctl", "--user", "unset-environment", "DISPLAY" })) {
        return error.SystemdEnvironmentUpdateFailed;
    }
    const updated = self.run(&.{ "dbus-update-activation-environment", "DISPLAY=" }) catch |err| {
        log.warn("could not clear DISPLAY from the D-Bus activation environment: {t}", .{err});
        return;
    };
    if (!updated) {
        // dbus-broker services still receive the systemd manager environment.
        log.warn("dbus-update-activation-environment exited unsuccessfully", .{});
    }
}

pub fn shutdown(self: *const Self) !void {
    if (!self.session_enabled) return;

    self.clearActivationEnvironment();
    const stopped = if (self.notify_enabled)
        try self.run(&.{
            "systemctl",
            "--user",
            "--no-block",
            "stop",
            "keywork-session.target",
            "graphical-session.target",
        })
    else
        try self.run(&.{
            "systemctl",
            "--user",
            "stop",
            "keywork-session.target",
            "graphical-session.target",
        });
    if (!stopped) return error.SessionTargetStopFailed;
}

fn clearActivationEnvironment(self: *const Self) void {
    var systemctl_argv: [3 + environment_names.len][]const u8 = undefined;
    systemctl_argv[0] = "systemctl";
    systemctl_argv[1] = "--user";
    systemctl_argv[2] = "unset-environment";
    @memcpy(systemctl_argv[3..], &environment_names);
    const cleared = self.run(&systemctl_argv) catch |err| failed: {
        log.warn("could not clear the systemd activation environment: {t}", .{err});
        break :failed false;
    };
    if (!cleared) log.warn("systemd activation environment cleanup failed", .{});

    const empty_assignments = [_][]const u8{
        "WAYLAND_DISPLAY=",
        "DISPLAY=",
        "KEYWORK_CONTROL=",
        "XDG_CURRENT_DESKTOP=",
        "XDG_SESSION_DESKTOP=",
        "XDG_SESSION_TYPE=",
        "XCURSOR_SIZE=",
    };
    var dbus_argv: [1 + empty_assignments.len][]const u8 = undefined;
    dbus_argv[0] = "dbus-update-activation-environment";
    @memcpy(dbus_argv[1..], &empty_assignments);
    const dbus_cleared = self.run(&dbus_argv) catch |err| failed: {
        log.warn("could not clear the D-Bus activation environment: {t}", .{err});
        break :failed false;
    };
    if (!dbus_cleared) log.warn("D-Bus activation environment cleanup failed", .{});
}

fn updateActivationEnvironment(self: *const Self, assignments: []const []const u8) !void {
    std.debug.assert(assignments.len > 0 and assignments.len <= max_assignments);

    var systemctl_argv: [3 + max_assignments][]const u8 = undefined;
    systemctl_argv[0] = "systemctl";
    systemctl_argv[1] = "--user";
    systemctl_argv[2] = "set-environment";
    @memcpy(systemctl_argv[3 .. 3 + assignments.len], assignments);
    if (!try self.run(systemctl_argv[0 .. 3 + assignments.len])) {
        return error.SystemdEnvironmentUpdateFailed;
    }

    var dbus_argv: [1 + max_assignments][]const u8 = undefined;
    dbus_argv[0] = "dbus-update-activation-environment";
    @memcpy(dbus_argv[1 .. 1 + assignments.len], assignments);
    const updated = self.run(dbus_argv[0 .. 1 + assignments.len]) catch |err| {
        log.warn("could not update the D-Bus activation environment: {t}", .{err});
        return;
    };
    if (!updated) {
        // dbus-broker services still receive the systemd manager environment.
        log.warn("dbus-update-activation-environment exited unsuccessfully", .{});
    }
}

fn run(self: *const Self, argv: []const []const u8) !bool {
    var child = try std.process.spawn(self.io, .{
        .argv = argv,
        .environ_map = self.environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const term = try child.wait(self.io);
    return switch (term) {
        .exited => |status| status == 0,
        else => false,
    };
}

test "native output enables session publication independently of notification" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();

    var systemd: Self = .init(std.testing.io, &environ_map, false);
    try std.testing.expect(!systemd.notify_enabled);
    try std.testing.expect(!systemd.session_enabled);

    try environ_map.put("NOTIFY_SOCKET", "/run/notify");
    systemd = .init(std.testing.io, &environ_map, false);
    try std.testing.expect(systemd.notify_enabled);
    try std.testing.expect(!systemd.session_enabled);

    systemd = .init(std.testing.io, &environ_map, true);
    try std.testing.expect(systemd.notify_enabled);
    try std.testing.expect(systemd.session_enabled);

    _ = environ_map.swapRemove("NOTIFY_SOCKET");
    systemd = .init(std.testing.io, &environ_map, true);
    try std.testing.expect(!systemd.notify_enabled);
    try std.testing.expect(systemd.session_enabled);
}
