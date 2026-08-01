//! Application entry point.

const std = @import("std");
const build_options = @import("build-options");
const ControlProtocol = @import("keywork-control");
const OutputBackend = @import("backend/output.zig");
const Config = @import("config.zig");
const Launcher = @import("launcher.zig");
const Logging = @import("logging.zig");
const Renderer = @import("render/Renderer.zig");
const render = @import("render/types.zig");
const Server = @import("server.zig");
const Systemd = @import("systemd.zig");

pub const std_options: std.Options = .{
    // Compile every level in; Logging applies the selected level at runtime.
    .log_level = .debug,
    .logFn = Logging.logFn,
};

const log = std.log.scoped(.main);
const default_cursor_size = "24";
const usage =
    \\usage: keywork-compositor [OPTIONS]
    \\
    \\options:
    \\  --config PATH             use an explicit configuration file
    \\  --output KIND             select drm, nested, or headless output
    \\  --renderer KIND           select cpu or vulkan rendering
    \\  --headless-size WIDTHxHEIGHT
    \\  --headless-scale SCALE
    \\  --headless-refresh HZ
    \\  --drm-device PATH         use an explicit DRM device
    \\  --log-level LEVEL         select error, warning, info, or debug logging
    \\  --version                 show the Keywork version
    \\  --help                    show this help
    \\
;

const StartupOptions = struct {
    help: bool = false,
    version: bool = false,
    config_path: ?[]const u8 = null,
    output: ?OutputBackend.Kind = null,
    renderer: ?Renderer.Kind = null,
    headless_size: ?render.Size = null,
    headless_scale: ?render.Scale = null,
    headless_refresh_millihertz: ?i32 = null,
    drm_device: ?[]const u8 = null,
    log_level: ?ControlProtocol.LogLevel = null,

    fn outputKind(self: StartupOptions) OutputBackend.Kind {
        return self.output orelse .drm;
    }

    fn rendererKind(self: StartupOptions) Renderer.Kind {
        return self.renderer orelse if (self.outputKind() == .drm) .vulkan else .cpu;
    }
};

pub fn main(init: std.process.Init) !void {
    var arguments = try init.minimal.args.iterateAllocator(init.gpa);
    defer arguments.deinit();
    _ = arguments.next();
    const options = parseArguments(&arguments) catch |err| {
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.File.stderr().writer(init.io, &buffer);
        writer.interface.print("keywork-compositor: {t}\n\n{s}", .{ err, usage }) catch {};
        writer.interface.flush() catch {};
        std.process.exit(2);
    };
    if (options.help) {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.File.stdout().writer(init.io, &buffer);
        defer writer.interface.flush() catch {};
        try writer.interface.writeAll(usage);
        return;
    }
    if (options.version) {
        var buffer: [128]u8 = undefined;
        var writer = std.Io.File.stdout().writer(init.io, &buffer);
        defer writer.interface.flush() catch {};
        try writer.interface.print("keywork-compositor {s}\n", .{build_options.version});
        return;
    }
    Logging.setLevel(options.log_level orelse Logging.defaultLevel());
    const output_kind = options.outputKind();
    const renderer_kind = options.rendererKind();
    const native_session = output_kind == .drm;
    if (native_session) {
        _ = init.environ_map.swapRemove("WAYLAND_DISPLAY");
        _ = init.environ_map.swapRemove("DISPLAY");
        // Stop leaking the obsolete control-address override from older sessions.
        _ = init.environ_map.swapRemove("KEYWORK_CONTROL");
        try init.environ_map.put("XDG_CURRENT_DESKTOP", "keywork");
        try init.environ_map.put("XDG_SESSION_DESKTOP", "keywork");
        try init.environ_map.put("XDG_SESSION_TYPE", "wayland");
    }
    const session_lock = if (native_session)
        try acquireSessionLock(
            init.gpa,
            init.io,
            init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory,
        )
    else
        null;
    defer if (session_lock) |file| file.close(init.io);
    var systemd: Systemd = .init(init.io, init.environ_map, native_session);
    try systemd.prepare();
    var launcher: Launcher = .init(init.gpa, init.io, init.environ_map);
    defer launcher.deinit();
    var virtual_output: Server.VirtualOutputConfig = .{};
    if (options.headless_size) |size| virtual_output.size = size;
    if (options.headless_scale) |scale| virtual_output.scale = scale;
    if (options.headless_refresh_millihertz) |refresh| {
        virtual_output.refresh_millihertz = refresh;
    }
    try ensureCursorSize(init.environ_map);
    const server = try Server.createWithVirtualOutput(
        init.gpa,
        init.io,
        renderer_kind,
        output_kind,
        options.drm_device,
        virtual_output,
    );
    defer server.destroy();
    var configuration = try Config.Store.init(
        init.gpa,
        init.io,
        init.environ_map,
        options.config_path,
    );
    server.setConfiguration(&configuration);
    server.watchAppearance(
        init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory,
    );

    const interrupt = try server.eventLoop().addSignal(
        *Server,
        @intFromEnum(std.posix.SIG.INT),
        terminate,
        server,
    );
    defer interrupt.remove();
    const terminate_signal = try server.eventLoop().addSignal(
        *Server,
        @intFromEnum(std.posix.SIG.TERM),
        terminate,
        server,
    );
    defer terminate_signal.remove();
    const reload_signal = try server.eventLoop().addSignal(
        *Server,
        @intFromEnum(std.posix.SIG.HUP),
        reloadConfiguration,
        server,
    );
    defer reload_signal.remove();
    const child_signal = try server.eventLoop().addSignal(
        *Server,
        @intFromEnum(std.posix.SIG.CHLD),
        reapChildren,
        server,
    );
    defer child_signal.remove();

    const socket_name = try server.listen();
    try server.configureXdgSessionStorage(
        init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory,
        if (native_session) "session" else socket_name,
    );
    try init.environ_map.put("WAYLAND_DISPLAY", socket_name);
    try server.listenControl(
        init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory,
    );
    server.setLauncher(&launcher);
    server.setXwaylandDisplayListener(.{
        .context = &systemd,
        .available = xwaylandDisplayAvailable,
        .unavailable = xwaylandDisplayUnavailable,
    });
    const xwayland_display = server.startXwayland(init.environ_map);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print("WAYLAND_DISPLAY={s}\n", .{socket_name});
    if (xwayland_display) |display_name|
        try writer.interface.print("DISPLAY={s}\n", .{display_name});
    try writer.interface.flush();
    systemd.ready(socket_name, init.environ_map.get("XCURSOR_SIZE").?) catch |err| {
        systemd.shutdown() catch |shutdown_err| {
            log.warn("failed to roll back graphical session startup: {t}", .{shutdown_err});
        };
        return err;
    };

    server.run();
    systemd.shutdown() catch |err| {
        log.warn("failed to shut down the graphical session targets: {t}", .{err});
    };
}

fn parseArguments(arguments: anytype) !StartupOptions {
    var options: StartupOptions = .{};
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--help")) {
            if (options.help) return error.DuplicateArgument;
            options.help = true;
        } else if (std.mem.eql(u8, argument, "--version")) {
            if (options.version) return error.DuplicateArgument;
            options.version = true;
        } else if (std.mem.eql(u8, argument, "--config")) {
            if (options.config_path != null) return error.DuplicateArgument;
            options.config_path = arguments.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, argument, "--output")) {
            if (options.output != null) return error.DuplicateArgument;
            const value = arguments.next() orelse return error.MissingArgument;
            options.output = std.meta.stringToEnum(OutputBackend.Kind, value) orelse
                return error.InvalidOutputBackend;
        } else if (std.mem.eql(u8, argument, "--renderer")) {
            if (options.renderer != null) return error.DuplicateArgument;
            const value = arguments.next() orelse return error.MissingArgument;
            options.renderer = std.meta.stringToEnum(Renderer.Kind, value) orelse
                return error.InvalidRenderer;
        } else if (std.mem.eql(u8, argument, "--headless-size")) {
            if (options.headless_size != null) return error.DuplicateArgument;
            const value = arguments.next() orelse return error.MissingArgument;
            options.headless_size = parseHeadlessSize(value) catch
                return error.InvalidHeadlessSize;
        } else if (std.mem.eql(u8, argument, "--headless-scale")) {
            if (options.headless_scale != null) return error.DuplicateArgument;
            const value = arguments.next() orelse return error.MissingArgument;
            options.headless_scale = parseHeadlessScale(value) catch
                return error.InvalidHeadlessScale;
        } else if (std.mem.eql(u8, argument, "--headless-refresh")) {
            if (options.headless_refresh_millihertz != null) return error.DuplicateArgument;
            const value = arguments.next() orelse return error.MissingArgument;
            options.headless_refresh_millihertz = parseHeadlessRefresh(value) catch
                return error.InvalidHeadlessRefresh;
        } else if (std.mem.eql(u8, argument, "--drm-device")) {
            if (options.drm_device != null) return error.DuplicateArgument;
            const value = arguments.next() orelse return error.MissingArgument;
            if (value.len == 0) return error.InvalidDrmDevice;
            options.drm_device = value;
        } else if (std.mem.eql(u8, argument, "--log-level")) {
            if (options.log_level != null) return error.DuplicateArgument;
            const value = arguments.next() orelse return error.MissingArgument;
            options.log_level = std.meta.stringToEnum(
                ControlProtocol.LogLevel,
                value,
            ) orelse return error.InvalidLogLevel;
        } else {
            return error.InvalidArgument;
        }
    }
    if (options.help or options.version) return options;
    const output = options.outputKind();
    if (output != .headless and
        (options.headless_size != null or options.headless_scale != null or
            options.headless_refresh_millihertz != null))
    {
        return error.HeadlessOptionRequiresHeadlessOutput;
    }
    if (output != .drm and options.drm_device != null) {
        return error.DrmDeviceRequiresDrmOutput;
    }
    return options;
}

fn ensureCursorSize(environ_map: *std.process.Environ.Map) !void {
    const cursor_size = environ_map.get("XCURSOR_SIZE") orelse "";
    if (cursor_size.len == 0) try environ_map.put("XCURSOR_SIZE", default_cursor_size);
}

fn xwaylandDisplayAvailable(context: *anyopaque, display_name: []const u8) void {
    const systemd: *Systemd = @ptrCast(@alignCast(context));
    systemd.publishDisplay(display_name) catch |err| {
        log.warn("failed to publish DISPLAY to the activation environment: {t}", .{err});
    };
}

fn xwaylandDisplayUnavailable(context: *anyopaque) void {
    const systemd: *Systemd = @ptrCast(@alignCast(context));
    systemd.unpublishDisplay() catch |err| {
        log.warn("failed to remove DISPLAY from the activation environment: {t}", .{err});
    };
}

fn acquireSessionLock(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_directory: []const u8,
) !std.Io.File {
    if (!std.fs.path.isAbsolute(runtime_directory)) return error.InvalidRuntimeDirectory;
    const path = try std.fs.path.join(allocator, &.{ runtime_directory, "keywork-compositor.lock" });
    defer allocator.free(path);
    return std.Io.Dir.createFileAbsolute(io, path, .{
        .truncate = false,
        .lock = .exclusive,
    });
}

fn parseHeadlessSize(value: []const u8) !render.Size {
    const separator = std.mem.indexOfScalar(u8, value, 'x') orelse
        return error.InvalidHeadlessSize;
    const width = std.fmt.parseInt(u32, value[0..separator], 10) catch
        return error.InvalidHeadlessSize;
    const height = std.fmt.parseInt(u32, value[separator + 1 ..], 10) catch
        return error.InvalidHeadlessSize;
    if (width == 0 or height == 0) return error.InvalidHeadlessSize;
    return .{ .width = width, .height = height };
}

fn parseHeadlessScale(value: []const u8) !render.Scale {
    const scale = std.fmt.parseFloat(f64, value) catch return error.InvalidHeadlessScale;
    const scaled = @round(scale * render.Scale.denominator);
    if (!std.math.isFinite(scaled) or scaled < 1 or
        scaled > @as(f64, @floatFromInt(std.math.maxInt(u32))))
    {
        return error.InvalidHeadlessScale;
    }
    return .{ .numerator = @intFromFloat(scaled) };
}

fn parseHeadlessRefresh(value: []const u8) !i32 {
    var source = value;
    if (std.mem.endsWith(u8, source, "Hz")) source = source[0 .. source.len - 2];
    const refresh = std.fmt.parseFloat(f64, source) catch return error.InvalidHeadlessRefresh;
    const millihertz = @round(refresh * 1000.0);
    if (!std.math.isFinite(millihertz) or millihertz < 1 or
        millihertz > @as(f64, @floatFromInt(std.math.maxInt(i32))))
    {
        return error.InvalidHeadlessRefresh;
    }
    return @intFromFloat(millihertz);
}

fn terminate(_: c_int, server: *Server) c_int {
    server.terminate();
    return 0;
}

fn reloadConfiguration(_: c_int, server: *Server) c_int {
    server.reloadConfiguration() catch |err| {
        log.warn("configuration reload failed: {t}", .{err});
    };
    return 0;
}

fn reapChildren(_: c_int, _: *Server) c_int {
    // Detached launchers and Xwayland deliberately transfer wait ownership here.
    while (std.c.waitpid(-1, null, std.os.linux.W.NOHANG) > 0) {}
    return 0;
}

const TestArguments = struct {
    values: []const []const u8,
    index: usize = 0,

    fn next(self: *@This()) ?[]const u8 {
        if (self.index == self.values.len) return null;
        defer self.index += 1;
        return self.values[self.index];
    }
};

test "startup options replace environment backend controls" {
    var defaults: TestArguments = .{ .values = &.{} };
    const default_options = try parseArguments(&defaults);
    try std.testing.expectEqual(OutputBackend.Kind.drm, default_options.outputKind());
    try std.testing.expectEqual(Renderer.Kind.vulkan, default_options.rendererKind());

    var configured: TestArguments = .{ .values = &.{
        "--config",
        "/tmp/keywork.conf",
        "--output",
        "headless",
        "--renderer",
        "vulkan",
        "--headless-size",
        "2880x1800",
        "--headless-scale",
        "1.5",
        "--headless-refresh",
        "120",
        "--log-level",
        "debug",
    } };
    const options = try parseArguments(&configured);
    try std.testing.expectEqualStrings("/tmp/keywork.conf", options.config_path.?);
    try std.testing.expectEqual(OutputBackend.Kind.headless, options.outputKind());
    try std.testing.expectEqual(Renderer.Kind.vulkan, options.rendererKind());
    try std.testing.expectEqual(render.Size{ .width = 2880, .height = 1800 }, options.headless_size.?);
    try std.testing.expectEqual(@as(u32, 180), options.headless_scale.?.numerator);
    try std.testing.expectEqual(@as(i32, 120_000), options.headless_refresh_millihertz.?);
    try std.testing.expectEqual(ControlProtocol.LogLevel.debug, options.log_level.?);

    var drm: TestArguments = .{ .values = &.{ "--drm-device", "/dev/dri/card1" } };
    const drm_options = try parseArguments(&drm);
    try std.testing.expectEqualStrings("/dev/dri/card1", drm_options.drm_device.?);

    var help: TestArguments = .{ .values = &.{ "--help", "--headless-size", "1920x1080" } };
    try std.testing.expect((try parseArguments(&help)).help);

    var version: TestArguments = .{ .values = &.{"--version"} };
    try std.testing.expect((try parseArguments(&version)).version);
}

test "startup options reject duplicates and backend-specific misuse" {
    var duplicate: TestArguments = .{ .values = &.{ "--output", "drm", "--output", "nested" } };
    try std.testing.expectError(error.DuplicateArgument, parseArguments(&duplicate));

    var missing: TestArguments = .{ .values = &.{"--renderer"} };
    try std.testing.expectError(error.MissingArgument, parseArguments(&missing));

    var invalid_output: TestArguments = .{ .values = &.{ "--output", "windowed" } };
    try std.testing.expectError(error.InvalidOutputBackend, parseArguments(&invalid_output));

    var invalid_log_level: TestArguments = .{ .values = &.{ "--log-level", "verbose" } };
    try std.testing.expectError(error.InvalidLogLevel, parseArguments(&invalid_log_level));

    var misplaced_headless: TestArguments = .{ .values = &.{ "--headless-size", "1920x1080" } };
    try std.testing.expectError(
        error.HeadlessOptionRequiresHeadlessOutput,
        parseArguments(&misplaced_headless),
    );

    var misplaced_drm: TestArguments = .{ .values = &.{
        "--output",
        "nested",
        "--drm-device",
        "/dev/dri/card1",
    } };
    try std.testing.expectError(
        error.DrmDeviceRequiresDrmOutput,
        parseArguments(&misplaced_drm),
    );
}

test "headless output configuration parses size, scale, and refresh" {
    try std.testing.expectEqual(
        render.Size{ .width = 2880, .height = 1800 },
        try parseHeadlessSize("2880x1800"),
    );
    try std.testing.expectEqual(@as(u32, 180), (try parseHeadlessScale("1.5")).numerator);
    try std.testing.expectEqual(@as(i32, 120_000), try parseHeadlessRefresh("120"));
    try std.testing.expectEqual(@as(i32, 59_940), try parseHeadlessRefresh("59.94Hz"));
    try std.testing.expectError(error.InvalidHeadlessSize, parseHeadlessSize("2880"));
    try std.testing.expectError(error.InvalidHeadlessScale, parseHeadlessScale("0"));
    try std.testing.expectError(error.InvalidHeadlessRefresh, parseHeadlessRefresh("0"));
}

test "cursor size defaults when missing or empty" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();

    try ensureCursorSize(&environ_map);
    try std.testing.expectEqualStrings(default_cursor_size, environ_map.get("XCURSOR_SIZE").?);

    try environ_map.put("XCURSOR_SIZE", "");
    try ensureCursorSize(&environ_map);
    try std.testing.expectEqualStrings(default_cursor_size, environ_map.get("XCURSOR_SIZE").?);

    try environ_map.put("XCURSOR_SIZE", "32");
    try ensureCursorSize(&environ_map);
    try std.testing.expectEqualStrings("32", environ_map.get("XCURSOR_SIZE").?);
}

test {
    _ = @import("wayring/ShmGlobal.zig");
    _ = @import("wayring/shm.zig");
    _ = @import("render/types.zig");
    _ = @import("render/backdrop_cache_key.zig");
    _ = @import("render/blur_geometry.zig");
    _ = @import("render/color_math.zig");
    _ = @import("render/command_geometry.zig");
    _ = @import("render/dual_kawase.zig");
    _ = @import("render/gpu_timing.zig");
    _ = @import("render/icc.zig");
    _ = @import("render/rect_region.zig");
    _ = @import("render/Renderer.zig");
    _ = @import("render/cpu.zig");
    _ = @import("render/vulkan.zig");
    _ = @import("render/vulkan_format.zig");
    _ = @import("backend/headless.zig");
    _ = @import("backend/nested_wayland.zig");
    _ = @import("backend/drm.zig");
    _ = @import("backend/BufferDamageTracker.zig");
    _ = @import("backend/ScanoutFramebufferCache.zig");
    _ = @import("backend/cursor_resample.zig");
    _ = @import("backend/display_color.zig");
    _ = @import("backend/drm_plane_assignment.zig");
    _ = @import("backend/drm_device.zig");
    _ = @import("backend/KeymapCompiler.zig");
    _ = @import("backend/native_input.zig");
    _ = @import("backend/output.zig");
    _ = @import("backend/session.zig");
    _ = @import("drm_syncobj.zig");
    _ = @import("presentation.zig");
    _ = @import("backdrop_blur_damage.zig");
    _ = @import("capture_geometry.zig");
    _ = @import("damage_geometry.zig");
    _ = @import("FrameStatistics.zig");
    _ = @import("input_configuration.zig");
    _ = @import("output_configuration.zig");
    _ = @import("region.zig");
    _ = @import("scene.zig");
    _ = @import("slot_map.zig");
    _ = @import("systemd.zig");
    _ = @import("window_geometry.zig");
    _ = @import("window_manager.zig");
    _ = @import("window_animation.zig");
    _ = @import("window_manager/ConfigureTransaction.zig");
    _ = @import("window_manager/drag_geometry.zig");
    _ = @import("window_manager/floating_placement.zig");
    _ = @import("window_manager/floating_resize.zig");
    _ = @import("builtin_keybindings.zig");
    _ = @import("AppearanceClient.zig");
    _ = @import("config.zig");
    _ = @import("theme.zig");
    _ = @import("launcher.zig");
    _ = @import("command.zig");
    _ = @import("input_manager.zig");
    _ = @import("window_manager/types.zig");
    _ = @import("window_manager/XwaylandController.zig");
    _ = @import("window_manager/TiledLayout.zig");
    _ = @import("window_manager/layout.zig");
    _ = @import("window_manager/workspace.zig");
    _ = @import("wayland/compositor.zig");
    _ = @import("wayland/surface.zig");
    _ = @import("wayland/surface_geometry.zig");
    _ = @import("wayland/region.zig");
    _ = @import("wayland/subcompositor.zig");
    _ = @import("wayland/seat.zig");
    _ = @import("wayland/PressedKeyState.zig");
    _ = @import("wayland/UserActionSerials.zig");
    _ = @import("wayland/transient_seat.zig");
    _ = @import("wayland/output.zig");
    _ = @import("wayland/output_layout.zig");
    _ = @import("wayland/output_management.zig");
    _ = @import("wayland/output_power.zig");
    _ = @import("wayland/gamma_control.zig");
    _ = @import("wayland/data_device.zig");
    _ = @import("wayland/primary_selection.zig");
    _ = @import("wayland/SelectionSource.zig");
    _ = @import("wayland/data_control.zig");
    _ = @import("wayland/foreign_toplevel_list.zig");
    _ = @import("wayland/image_capture_source.zig");
    _ = @import("wayland/image_copy_capture.zig");
    _ = @import("wayland/screencopy.zig");
    _ = @import("wayland/xwayland_shell.zig");
    _ = @import("xwayland/selection.zig");
    _ = @import("xwayland/server.zig");
    _ = @import("xwayland/window_policy.zig");
    _ = @import("xwayland/xwm.zig");
    _ = @import("wayland/workspace.zig");
    _ = @import("wayland/text_input.zig");
    _ = @import("wayland/input_method.zig");
    _ = @import("wayland/virtual_keyboard.zig");
    _ = @import("wayland/virtual_pointer.zig");
    _ = @import("wayland/presentation.zig");
    _ = @import("wayland/fractional_scale.zig");
    _ = @import("wayland/fixes.zig");
    _ = @import("wayland/linux_dmabuf.zig");
    _ = @import("wayland/linux_drm_syncobj.zig");
    _ = @import("wayland/tearing_control.zig");
    _ = @import("wayland/fifo.zig");
    _ = @import("wayland/commit_timing.zig");
    _ = @import("wayland/xdg_toplevel_drag.zig");
    _ = @import("wayland/xdg_toplevel_icon.zig");
    _ = @import("wayland/xdg_dialog.zig");
    _ = @import("wayland/xdg_system_bell.zig");
    _ = @import("wayland/xdg_toplevel_tag.zig");
    _ = @import("wayland/xdg_session_management.zig");
    _ = @import("wayland/single_pixel_buffer.zig");
    _ = @import("wayland/content_type.zig");
    _ = @import("wayland/color_management.zig");
    _ = @import("wayland/color_representation.zig");
    _ = @import("wayland/alpha_modifier.zig");
    _ = @import("wayland/background_effect.zig");
    _ = @import("wayland/security_context.zig");
    _ = @import("wayland/drm_lease.zig");
    _ = @import("wayland/session_lock.zig");
    _ = @import("wayland/cursor_shape.zig");
    _ = @import("wayland/tablet.zig");
    _ = @import("wayland/pointer_gestures.zig");
    _ = @import("wayland/relative_pointer.zig");
    _ = @import("wayland/pointer_constraints.zig");
    _ = @import("wayland/pointer_warp.zig");
    _ = @import("wayland/idle_inhibit.zig");
    _ = @import("wayland/keyboard_shortcuts_inhibit.zig");
    _ = @import("wayland/idle_notify.zig");
    _ = @import("wayland/xdg_activation.zig");
    _ = @import("wayland/xdg_foreign.zig");
    _ = @import("wayland/xdg_output.zig");
    _ = @import("wayland/viewporter.zig");
    _ = @import("wayland/gtk_shell.zig");
    _ = @import("wayland/xdg_popup_placement.zig");
    _ = @import("wayland/xdg_shell.zig");
    _ = @import("wayland/layer_shell.zig");
    _ = @import("control.zig");
    _ = @import("server.zig");
}
