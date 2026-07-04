//! Keywork demo application consuming libkeywork.

const std = @import("std");
const keywork = @import("libkeywork");
const lua_app = @import("lua_app.zig");

const log = std.log.scoped(.keywork);

const AppContext = keywork.AppContext;
const AppHost = keywork.AppHost;
const Constraints = keywork.Constraints;
const LogBackend = keywork.LogBackend;
const Runtime = keywork.Runtime;
const Widget = keywork.Widget;
const desktop_settings = keywork.desktop_settings;
const event_loop = keywork.event_loop;
const wayland_shm = keywork.wayland_shm;
const wayland_vulkan = keywork.wayland_vulkan;

const DemoApp = struct {
    lua: *lua_app.App,
    button_pressed: bool = false,
    pulse: bool = false,

    pub fn host(self: *DemoApp) AppHost {
        return .{ .ptr = self, .vtable = &.{
            .build_widget = buildWidget,
            .click = click,
            .timer = timer,
        } };
    }

    fn buildWidget(ptr: *anyopaque, allocator: std.mem.Allocator, context: AppContext) !Widget {
        const self: *DemoApp = @ptrCast(@alignCast(ptr));
        var app_context = context;
        app_context.button_pressed = self.button_pressed;
        app_context.pulse = self.pulse;
        return self.lua.buildWidget(allocator, app_context);
    }

    fn click(ptr: *anyopaque, id: []const u8) !bool {
        const self: *DemoApp = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, id, "hello")) return false;
        self.button_pressed = !self.button_pressed;
        return true;
    }

    fn timer(ptr: *anyopaque, expirations: u64) !bool {
        const self: *DemoApp = @ptrCast(@alignCast(ptr));
        if (expirations == 0) return false;
        self.pulse = !self.pulse;
        return true;
    }
};

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    const backend_kind = selectedBackend(init);
    const constraints: Constraints = .{ .max_width = 640, .max_height = 480 };
    var lua = try lua_app.App.init(allocator, "main.lua");
    defer lua.deinit();
    var demo_app: DemoApp = .{ .lua = &lua };
    var settings_client: ?desktop_settings.Client = desktop_settings.Client.init() catch |err| blk: {
        log.warn("desktop settings unavailable: {}", .{err});
        break :blk null;
    };
    defer if (settings_client) |*settings| settings.deinit();
    const initial_color_scheme: desktop_settings.ColorScheme = if (settings_client) |settings| settings.color_scheme else .no_preference;

    if (backend_kind == .vulkan) {
        var backend = try wayland_vulkan.Backend.create(allocator, .{
            .title = "Keywork MVP (Vulkan)",
            .width = try positiveU31(constraints.max_width),
            .height = try positiveU31(constraints.max_height),
        });
        defer backend.destroy();

        var runtime = try Runtime.init(allocator, backend.renderBackend(), constraints, demo_app.host(), initial_color_scheme);
        defer runtime.deinit();
        backend.setClickHandler(&runtime, Runtime.waylandClick);
        backend.setRepaintHandler(&runtime, Runtime.waylandConfigure);
        backend.setFrameHandler(&runtime, Runtime.waylandFrameDone);
        backend.setKeyHandler(&runtime, Runtime.waylandKeyInput);
        if (settings_client) |*settings| {
            try settings.installSignalFilter();
            settings.setChangeHandler(&runtime, Runtime.desktopSettingsChanged);
        }
        try runtime.repaint();

        var loop = try event_loop.EventLoop.init(allocator);
        defer loop.deinit();
        try loop.setWayland(.{
            .fd = backend.eventLoopFd(),
            .ctx = backend,
            .prepare = wayland_vulkan.Backend.eventLoopPrepare,
            .finish = wayland_vulkan.Backend.eventLoopFinish,
        });
        try backend.installKeyRepeat(&loop);
        defer backend.uninstallKeyRepeat();
        if (settings_client) |*settings| try loop.addFd(.{
            .fd = settings.eventLoopFd(),
            .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.HUP,
            .ctx = settings,
            .callback = desktop_settings.Client.eventLoopCallback,
        });
        try loop.addRepeatingTimer(1000, &runtime, Runtime.timerTick);
        loop.addFileWatch("main.lua", &runtime, Runtime.fileChanged) catch |err| {
            if (err != error.FileWatchNotFound) log.warn("main.lua watch not installed: {}", .{err});
        };
        try loop.run();
        return;
    }

    if (backend_kind == .wayland_shm) {
        var backend = try wayland_shm.Backend.create(allocator, .{
            .title = "Keywork MVP",
            .width = try positiveU31(constraints.max_width),
            .height = try positiveU31(constraints.max_height),
        });
        defer backend.destroy();

        var runtime = try Runtime.init(allocator, backend.renderBackend(), constraints, demo_app.host(), initial_color_scheme);
        defer runtime.deinit();
        backend.setClickHandler(&runtime, Runtime.waylandClick);
        backend.setRepaintHandler(&runtime, Runtime.waylandConfigure);
        backend.setFrameHandler(&runtime, Runtime.waylandFrameDone);
        backend.setKeyHandler(&runtime, Runtime.waylandKeyInput);
        if (settings_client) |*settings| {
            try settings.installSignalFilter();
            settings.setChangeHandler(&runtime, Runtime.desktopSettingsChanged);
        }
        try runtime.repaint();

        var loop = try event_loop.EventLoop.init(allocator);
        defer loop.deinit();
        try loop.setWayland(.{
            .fd = backend.eventLoopFd(),
            .ctx = backend,
            .prepare = wayland_shm.Backend.eventLoopPrepare,
            .finish = wayland_shm.Backend.eventLoopFinish,
        });
        try backend.installKeyRepeat(&loop);
        defer backend.uninstallKeyRepeat();
        if (settings_client) |*settings| try loop.addFd(.{
            .fd = settings.eventLoopFd(),
            .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.HUP,
            .ctx = settings,
            .callback = desktop_settings.Client.eventLoopCallback,
        });
        try loop.addRepeatingTimer(1000, &runtime, Runtime.timerTick);
        loop.addFileWatch("main.lua", &runtime, Runtime.fileChanged) catch |err| {
            if (err != error.FileWatchNotFound) log.warn("main.lua watch not installed: {}", .{err});
        };
        try loop.run();
        return;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    var backend: LogBackend = .{ .writer = &stdout_writer.interface };
    var runtime = try Runtime.init(allocator, backend.backend(), constraints, demo_app.host(), initial_color_scheme);
    defer runtime.deinit();
    try runtime.repaint();

    const root = if (runtime.root) |*root| root else return error.NotBuilt;
    if (keywork.hitTestButton(root, .{ .x = 40, .y = 190 })) |id| {
        try stdout_writer.interface.print("hit button {s}\n", .{id});
    } else {
        try stdout_writer.interface.print("hit nothing\n", .{});
    }

    log.debug("frame rendered", .{});
}

const BackendKind = enum { log, wayland_shm, vulkan };

fn selectedBackend(init: std.process.Init) BackendKind {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--wayland")) return .wayland_shm;
        if (std.mem.eql(u8, arg, "--backend=shm")) return .wayland_shm;
        if (std.mem.eql(u8, arg, "--backend=vulkan")) return .vulkan;
    }
    return .log;
}

fn positiveU31(value: f32) !u31 {
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidFrameSize;
    const rounded = @ceil(value);
    if (rounded > @as(f32, @floatFromInt(std.math.maxInt(u31)))) return error.InvalidFrameSize;
    return @intFromFloat(rounded);
}
