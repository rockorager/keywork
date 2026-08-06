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
const WayringCompositor = @import("wayland/WayringCompositor.zig");
const WayringClients = @import("wayland/WayringClients.zig");
const WayringCursorShape = @import("wayland/WayringCursorShape.zig");
const WayringXdgDecoration = @import("wayland/WayringXdgDecoration.zig");
const WayringXdgActivation = @import("wayland/WayringXdgActivation.zig");
const WayringFractionalScale = @import("wayland/WayringFractionalScale.zig");
const WayringHost = @import("wayland/WayringHost.zig");
const WayringOutput = @import("wayland/WayringOutput.zig");
const WayringSeatAdapter = @import("wayland/WayringSeatAdapter.zig");
const WayringXdgShell = @import("wayland/WayringXdgShell.zig");
const WayringViewporter = @import("wayland/WayringViewporter.zig");
const wayring = @import("wayring");

comptime {
    _ = @import("DataDevice.zig");
}

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
    \\  --experimental-wayring    open a scanner-backed sidecar socket
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
    experimental_wayring: bool = false,
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
    var wayring_protocol_server: ?wayring.server.Server = null;
    var wayring_clients: WayringClients = undefined;
    var wayring_clients_initialized = false;
    var wayring_compositor: WayringCompositor = undefined;
    var wayring_compositor_initialized = false;
    var wayring_outputs: WayringOutput = undefined;
    var wayring_outputs_initialized = false;
    var wayring_xdg_shell: WayringXdgShell = undefined;
    var wayring_xdg_shell_initialized = false;
    var wayring_xdg_shell_published = false;
    var wayring_viewporter: WayringViewporter = undefined;
    var wayring_viewporter_initialized = false;
    var wayring_viewporter_published = false;
    var wayring_fractional_scale: WayringFractionalScale = undefined;
    var wayring_fractional_scale_initialized = false;
    var wayring_fractional_scale_published = false;
    var wayring_cursor_shape: WayringCursorShape = undefined;
    var wayring_cursor_shape_initialized = false;
    var wayring_cursor_shape_published = false;
    var wayring_xdg_decoration: WayringXdgDecoration = undefined;
    var wayring_xdg_decoration_initialized = false;
    var wayring_xdg_decoration_published = false;
    var wayring_xdg_activation: WayringXdgActivation = undefined;
    var wayring_xdg_activation_initialized = false;
    var wayring_xdg_activation_published = false;
    var wayring_seat_adapter: WayringSeatAdapter = undefined;
    var wayring_seat_adapter_initialized = false;
    var wayring_seat_published = false;
    const WayringLifecycle = struct {
        clients: *WayringClients,
        outputs: ?*WayringOutput,
        xdg_shell: *WayringXdgShell,
        viewporter: *WayringViewporter,
        fractional_scale: ?*WayringFractionalScale,
        cursor_shape: ?*WayringCursorShape,
        xdg_decoration: ?*WayringXdgDecoration,
        xdg_activation: ?*WayringXdgActivation,
        compositor: *WayringCompositor,
        seat: *WayringSeatAdapter,

        fn accepted(erased: *anyopaque, client: *wayring.server.Client) !void {
            const self: *@This() = @ptrCast(@alignCast(erased));
            _ = try self.clients.register(client);
            errdefer self.clients.unregister(client);
            try self.seat.trackClient(client);
        }

        fn destroy(erased: *anyopaque, client: *wayring.server.Client) void {
            const self: *@This() = @ptrCast(@alignCast(erased));
            if (self.xdg_activation) |activation| activation.destroyClientResources(client);
            if (self.xdg_decoration) |decoration| decoration.destroyClientResources(client);
            if (self.cursor_shape) |cursor_shape| cursor_shape.destroyClientResources(client);
            self.seat.destroyClientResources(client);
            if (self.fractional_scale) |fractional_scale|
                fractional_scale.destroyClientResources(client);
            self.viewporter.destroyClientResources(client);
            self.xdg_shell.destroyClientResources(client);
            if (self.outputs) |outputs| outputs.destroyClientResources(client);
            self.compositor.destroyClientResources(client);
            if (self.clients.id(client) != null) self.clients.unregister(client);
        }
    };
    var wayring_lifecycle: WayringLifecycle = undefined;
    var wayring_host: ?*WayringHost = null;
    defer {
        if (wayring_host) |host| host.destroy() catch |err| {
            log.warn("failed to shut down experimental Wayring socket: {t}", .{err});
        };
        if (wayring_xdg_activation_initialized) {
            if (wayring_xdg_activation_published) wayring_xdg_activation.unpublish();
            wayring_xdg_activation.deinit();
        }
        if (wayring_xdg_decoration_initialized) {
            if (wayring_xdg_decoration_published) wayring_xdg_decoration.unpublish();
            wayring_xdg_decoration.deinit();
        }
        if (wayring_cursor_shape_initialized) {
            if (wayring_cursor_shape_published) wayring_cursor_shape.unpublish();
            wayring_cursor_shape.deinit();
        }
        if (wayring_fractional_scale_initialized) {
            server.clearWayringDefaultOutputListener(&wayring_fractional_scale);
            if (wayring_fractional_scale_published) wayring_fractional_scale.unpublish();
            wayring_fractional_scale.deinit();
        }
        if (wayring_viewporter_initialized) {
            if (wayring_viewporter_published) wayring_viewporter.unpublish();
            wayring_viewporter.deinit();
        }
        if (wayring_xdg_shell_initialized) {
            if (wayring_xdg_shell_published) wayring_xdg_shell.unpublish();
            wayring_xdg_shell.deinit();
        }
        if (wayring_outputs_initialized) wayring_outputs.deinit();
        if (wayring_seat_adapter_initialized) {
            if (wayring_seat_published) wayring_seat_adapter.unpublish();
            server.clearGeneratedSeatDeliverySink(&wayring_seat_adapter);
            wayring_seat_adapter.clearCursorListener();
            wayring_seat_adapter.deinit();
            wayring_seat_adapter_initialized = false;
        }
        if (wayring_clients_initialized) wayring_clients.deinit();
        if (wayring_compositor_initialized) wayring_compositor.deinit();
        if (wayring_protocol_server) |*protocol_server| protocol_server.deinit();
    }
    if (options.experimental_wayring) {
        wayring_protocol_server = .init(init.gpa);
        wayring_clients.init(init.gpa, server.clientRegistry());
        wayring_clients_initialized = true;
        try wayring_compositor.init(
            init.gpa,
            &wayring_protocol_server.?,
            server.surfaceRegistry(),
            // Phase 1 exposes scanner-backed surfaces only on headless
            // output. DRM and nested sidecars still copy and release through
            // the canonical registry without acquiring presentation policy.
            server.wayringPresentationListener(),
        );
        wayring_compositor_initialized = true;
        wayring_seat_adapter = .init(
            init.gpa,
            &wayring_protocol_server.?,
            &wayring_clients,
            &wayring_compositor,
            server.generatedSeatRequestSink(),
            server.generatedSeatName(),
        );
        wayring_seat_adapter_initialized = true;
        wayring_cursor_shape.init(
            init.gpa,
            &wayring_protocol_server.?,
            &wayring_seat_adapter,
            server.generatedCursorShape(),
            server.generatedSeatRequestSink(),
        );
        wayring_cursor_shape_initialized = true;
        wayring_seat_adapter.installCursorListener();
        server.setGeneratedSeatDeliverySink(wayring_seat_adapter.sink());
        try wayring_seat_adapter.publish();
        wayring_seat_published = true;
        if (server.wayringOutputLayout()) |output_layout| {
            try wayring_outputs.init(
                init.gpa,
                &wayring_protocol_server.?,
                output_layout,
                &wayring_compositor,
            );
            wayring_outputs_initialized = true;
        }
        wayring_xdg_shell.init(
            init.gpa,
            &wayring_protocol_server.?,
            server.neutralXdgShell(),
            &wayring_clients,
            &wayring_compositor,
            if (wayring_outputs_initialized) &wayring_outputs else null,
        );
        wayring_xdg_shell.setSeatAdapter(&wayring_seat_adapter);
        wayring_xdg_shell_initialized = true;
        wayring_xdg_decoration.init(init.gpa, &wayring_protocol_server.?, &wayring_xdg_shell, server.neutralXdgShell());
        wayring_xdg_decoration_initialized = true;
        wayring_xdg_activation.init(init.gpa, &wayring_protocol_server.?, &wayring_seat_adapter, &wayring_xdg_shell, server.xdgActivationOwner());
        wayring_xdg_activation_initialized = true;
        wayring_viewporter.init(init.gpa, &wayring_protocol_server.?, &wayring_compositor);
        wayring_viewporter_initialized = true;
        if (wayring_outputs_initialized) {
            try wayring_fractional_scale.init(
                init.gpa,
                &wayring_protocol_server.?,
                &wayring_compositor,
                &wayring_outputs,
                server.wayringOutputLayout().?,
                server.wayringDefaultOutputId().?,
            );
            wayring_fractional_scale_initialized = true;
            server.setWayringDefaultOutputListener(.{
                .context = &wayring_fractional_scale,
                .changed = WayringFractionalScale.defaultOutputChanged,
            });
        }
        // Stable generated XDG is authoritative only on the headless path
        // where generated output/presentation policy is available. Outputs
        // and the seat are deliberately published before this shell global.
        if (wayring_outputs_initialized) {
            try wayring_xdg_shell.publish();
            wayring_xdg_shell_published = true;
            try wayring_viewporter.publish();
            wayring_viewporter_published = true;
            try wayring_fractional_scale.publish();
            wayring_fractional_scale_published = true;
            try wayring_cursor_shape.publish();
            wayring_cursor_shape_published = true;
            try wayring_xdg_decoration.publish();
            wayring_xdg_decoration_published = true;
            try wayring_xdg_activation.publish();
            wayring_xdg_activation_published = true;
        }
        wayring_lifecycle = .{
            .clients = &wayring_clients,
            .outputs = if (wayring_outputs_initialized) &wayring_outputs else null,
            .xdg_shell = &wayring_xdg_shell,
            .viewporter = &wayring_viewporter,
            .fractional_scale = if (wayring_fractional_scale_initialized) &wayring_fractional_scale else null,
            .cursor_shape = if (wayring_cursor_shape_initialized) &wayring_cursor_shape else null,
            .xdg_decoration = if (wayring_xdg_decoration_initialized) &wayring_xdg_decoration else null,
            .xdg_activation = if (wayring_xdg_activation_initialized) &wayring_xdg_activation else null,
            .compositor = &wayring_compositor,
            .seat = &wayring_seat_adapter,
        };
        wayring_host = try WayringHost.create(
            init.gpa,
            server.eventLoop(),
            &wayring_protocol_server.?,
            init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory,
            .{
                .context = &wayring_lifecycle,
                .accepted = WayringLifecycle.accepted,
                .destroy_resources = WayringLifecycle.destroy,
            },
        );
        if (wayring_host.?.failure()) |err| return err;
    }
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
    if (wayring_host) |host|
        try writer.interface.print("KEYWORK_WAYRING_DISPLAY={s}\n", .{host.displayName()});
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
        } else if (std.mem.eql(u8, argument, "--experimental-wayring")) {
            if (options.experimental_wayring) return error.DuplicateArgument;
            options.experimental_wayring = true;
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
        "--experimental-wayring",
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
    try std.testing.expect(options.experimental_wayring);
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

    var duplicate_wayring: TestArguments = .{ .values = &.{ "--experimental-wayring", "--experimental-wayring" } };
    try std.testing.expectError(error.DuplicateArgument, parseArguments(&duplicate_wayring));

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
    _ = @import("HeadlessSurfaceForest.zig");
    _ = @import("SurfaceRegistry.zig");
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
    _ = @import("wayland/WayringCompositor.zig");
    _ = @import("wayland/WayringXdgShell.zig");
    _ = @import("wayland/WayringViewporter.zig");
    _ = @import("wayland/WayringClients.zig");
    _ = @import("wayland/WayringHost.zig");
    _ = @import("wayland/WayringOutput.zig");
    _ = @import("wayland/WayringSeatAdapter.zig");
    _ = @import("wayland/surface.zig");
    _ = @import("wayland/surface_geometry.zig");
    _ = @import("wayland/region.zig");
    _ = @import("wayland/subcompositor.zig");
    _ = @import("wayland/seat.zig");
    _ = @import("wayland/PressedKeyState.zig");
    _ = @import("wayland/mature_serials.zig");
    _ = @import("ClientRegistry.zig");
    _ = @import("wayland/MatureClients.zig");
    _ = @import("SeatAuthority.zig");
    _ = @import("SeatDelivery.zig");
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
    _ = @import("wayland/WayringFractionalScale.zig");
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
    _ = @import("wayland/WayringCursorShape.zig");
    _ = @import("wayland/WayringXdgDecoration.zig");
    _ = @import("wayland/WayringXdgActivation.zig");
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
    _ = @import("xdg_popup_placement.zig");
    _ = @import("XdgShell.zig");
    _ = @import("wayland/xdg_shell.zig");
    _ = @import("wayland/layer_shell.zig");
    _ = @import("control.zig");
    _ = @import("server.zig");
}
