//! Concrete Keywork application lifecycle owner.

const std = @import("std");
const cli = @import("cli.zig");
const native_runtime = @import("keywork-runtime");
const event_loop = @import("keywork-loop");
const SystemdEvent = native_runtime.SystemdEvent;
const lua_module = @import("keywork-lua");

const Application = @This();

allocator: std.mem.Allocator,
loop: event_loop.EventLoop,
systemd_event: *SystemdEvent,
lua: lua_module.App,

pub fn init(allocator: std.mem.Allocator, script_path: []const u8) !Application {
    var loop = try event_loop.EventLoop.init(allocator);
    errdefer loop.deinit();
    const systemd_event = try SystemdEvent.create(allocator);
    errdefer systemd_event.destroy(allocator);
    var lua = try lua_module.App.init(allocator, script_path);
    errdefer lua.deinit();
    lua.useSystemdEvent(systemd_event);
    return .{
        .allocator = allocator,
        .loop = loop,
        .systemd_event = systemd_event,
        .lua = lua,
    };
}

pub fn deinit(self: *Application) void {
    self.lua.unbindInvalidator();
    self.lua.unbindEventLoop();
    self.lua.deinit();
    self.systemd_event.unregister();
    self.systemd_event.destroy(self.allocator);
    self.loop.deinit();
}

pub fn run(
    self: *Application,
    init_io: std.Io,
    runtime_directory: []const u8,
    run_options: cli.Options,
) !void {
    try self.systemd_event.register(&self.loop);
    defer self.systemd_event.unregister();
    self.lua.setScriptArgs(run_options.app_args);
    try self.lua.ensureLoaded();
    const window = self.lua.window_config;

    const layer_shell = run_options.layer_shell orelse window.layer_shell;
    // Apps declaring a window set need a windowing backend by default.
    const backend = run_options.backend orelse window.backend orelse
        if (layer_shell != null or window.has_windows or window.session_lock) native_runtime.BackendKind.wayland_shm else .log;
    const title: [:0]const u8 = window.title orelse
        if (backend == .vulkan) "Keywork MVP (Vulkan)" else "Keywork MVP";
    const app_id = window.app_id orelse "dev.keywork.Keywork";

    const control = try native_runtime.ApplicationControl.create(
        self.allocator,
        init_io,
        self.systemd_event,
        runtime_directory,
        app_id,
        self.lua.reloadHost(),
    );
    defer control.destroy();
    self.lua.setReloadObserver(control.observer());
    defer self.lua.setReloadObserver(null);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init_io, &stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    try native_runtime.run(self.allocator, &self.loop, self.lua.host(), .{
        .title = title,
        .app_id = app_id,
        .width = run_options.width orelse window.width orelse 640,
        .height = run_options.height orelse window.height orelse 480,
        .backend = backend,
        .decorations = window.decorations orelse .server,
        .layer_shell = layer_shell,
        .background_blur = window.background_blur,
        .session_lock = window.session_lock,
        .log_writer = &stdout_writer.interface,
        .systemd_event = self.systemd_event,
        .host_bindings = self.lua.hostBindings(),
        .keep_alive = true,
        .windows_host = self.lua.windowsHost(),
    });
}
