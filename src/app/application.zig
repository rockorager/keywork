//! Concrete Keywork application lifecycle owner.

const std = @import("std");
const cli = @import("cli.zig");
const app_options = @import("options.zig");
const runner = @import("runner.zig");
const event_loop = @import("../linux/event_loop.zig");
const lua_module = @import("../lua/app.zig");
const runtime_mod = @import("../ui/runtime.zig");

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

    const layer_shell = run_options.layer_shell orelse window.layer_shell;
    // Apps declaring a window set need a windowing backend by default.
    const backend = run_options.backend orelse window.backend orelse
        if (layer_shell != null or window.has_windows) app_options.BackendKind.wayland_shm else .log;
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
        .layer_shell = layer_shell,
        .log_writer = &stdout_writer.interface,
        .runtime_context = &self.lua,
        .windows_host = self.lua.windowsHost(),
        .bind_runtime = bindLuaRuntime,
        .bind_invalidator = bindLuaInvalidator,
        .unbind_runtime = unbindLuaRuntime,
        .bind_event_loop = bindLuaEventLoop,
        .unbind_event_loop = unbindLuaEventLoop,
        .should_run_headless = luaShouldRunHeadless,
    });
}

fn bindLuaRuntime(ctx: *anyopaque, runtime: *runtime_mod.Runtime) void {
    const lua: *lua_module.App = @ptrCast(@alignCast(ctx));
    lua.bindRuntime(runtime);
}

fn bindLuaInvalidator(ctx: *anyopaque, invalidator: runtime_mod.Invalidator) void {
    const lua: *lua_module.App = @ptrCast(@alignCast(ctx));
    lua.bindInvalidator(invalidator);
}

fn unbindLuaRuntime(ctx: *anyopaque) void {
    const lua: *lua_module.App = @ptrCast(@alignCast(ctx));
    lua.unbindRuntime();
}

fn bindLuaEventLoop(ctx: *anyopaque, loop: *event_loop.EventLoop) anyerror!void {
    const lua: *lua_module.App = @ptrCast(@alignCast(ctx));
    try lua.bindEventLoop(loop);
}

fn unbindLuaEventLoop(ctx: *anyopaque) void {
    const lua: *lua_module.App = @ptrCast(@alignCast(ctx));
    lua.unbindEventLoop();
}

fn luaShouldRunHeadless(ctx: *anyopaque) bool {
    const lua: *lua_module.App = @ptrCast(@alignCast(ctx));
    return lua.hasLiveAsyncResources();
}
