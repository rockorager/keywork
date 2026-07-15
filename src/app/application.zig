//! Concrete Keywork application lifecycle owner.

const std = @import("std");
const cli = @import("cli.zig");
const app_options = @import("options.zig");
const runner = @import("runner.zig");
const river_window_manager = @import("river_window_manager.zig");
const event_loop = @import("../linux/event_loop.zig");
const lua_module = @import("../lua/app.zig");

const Application = @This();

allocator: std.mem.Allocator,
loop: event_loop.EventLoop,
lua: lua_module.App,

pub fn init(allocator: std.mem.Allocator, script_path: []const u8) !Application {
    var loop = try event_loop.EventLoop.init(allocator);
    errdefer loop.deinit();
    var lua = try lua_module.App.init(allocator, script_path);
    errdefer lua.deinit();
    return .{ .allocator = allocator, .loop = loop, .lua = lua };
}

pub fn deinit(self: *Application) void {
    self.lua.unbindRuntime();
    self.lua.unbindEventLoop();
    self.lua.deinit();
    self.loop.deinit();
}

pub fn run(self: *Application, init_io: std.Io, run_options: cli.Options) !void {
    self.lua.setScriptArgs(run_options.app_args);
    try self.lua.ensureLoaded();
    const window = self.lua.window_config;

    if (window.kind == .river_window_manager) {
        var river_host = self.lua.riverPolicyHost();
        try self.lua.bindEventLoop(&self.loop);
        defer self.lua.unbindEventLoop();
        return river_window_manager.run(self.allocator, &self.loop, &river_host);
    }

    const layer_shell = run_options.layer_shell orelse window.layer_shell;
    // Apps declaring a window set need a windowing backend by default.
    const backend = run_options.backend orelse window.backend orelse
        if (layer_shell != null or window.has_windows or window.session_lock) app_options.BackendKind.wayland_shm else .log;
    const title: [:0]const u8 = window.title orelse
        if (backend == .vulkan) "Keywork MVP (Vulkan)" else "Keywork MVP";

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init_io, &stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    try runner.run(self.allocator, &self.loop, self.lua.host(), .{
        .title = title,
        .app_id = window.app_id orelse "dev.keywork.Keywork",
        .width = run_options.width orelse window.width orelse 640,
        .height = run_options.height orelse window.height orelse 480,
        .backend = backend,
        .decorations = window.decorations orelse .server,
        .layer_shell = layer_shell,
        .session_lock = window.session_lock,
        .log_writer = &stdout_writer.interface,
        .runtime_context = &self.lua,
        .windows_host = self.lua.windowsHost(),
        .bind_runtime = lua_module.App.bindRuntimeOpaque,
        .bind_invalidator = lua_module.App.bindInvalidatorOpaque,
        .bind_platform = lua_module.App.bindPlatformOpaque,
        .unbind_platform = lua_module.App.unbindPlatformOpaque,
        .unbind_runtime = lua_module.App.unbindRuntimeOpaque,
        .bind_event_loop = lua_module.App.bindEventLoopOpaque,
        .unbind_event_loop = lua_module.App.unbindEventLoopOpaque,
        .should_run_headless = lua_module.App.shouldRunHeadlessOpaque,
    });
}
