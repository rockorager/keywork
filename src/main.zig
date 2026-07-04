//! Keywork demo application consuming libkeywork.

const std = @import("std");
const keywork = @import("libkeywork");
const lua_app = @import("lua_app.zig");

const log = std.log.scoped(.keywork);

const AppContext = keywork.AppContext;
const AppHost = keywork.AppHost;
const BuildScope = keywork.BuildScope;
const Widget = keywork.Widget;

const DemoApp = struct {
    lua: *lua_app.App,
    pulse: bool = false,

    pub fn host(self: *DemoApp) AppHost {
        return .{ .ptr = self, .vtable = &.{
            .build_widget = buildWidget,
            .timer = timer,
        } };
    }

    fn buildWidget(ptr: *anyopaque, scope: *BuildScope, context: AppContext) !Widget {
        const self: *DemoApp = @ptrCast(@alignCast(ptr));
        var app_context = context;
        app_context.pulse = self.pulse;
        return self.lua.buildWidget(scope.allocator, app_context);
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
    var lua = try lua_app.App.init(allocator, "main.lua");
    defer lua.deinit();
    var demo_app: DemoApp = .{ .lua = &lua };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    try keywork.run(allocator, demo_app.host(), .{
        .title = if (backend_kind == .vulkan) "Keywork MVP (Vulkan)" else "Keywork MVP",
        .width = 640,
        .height = 480,
        .backend = backend_kind,
        .log_writer = &stdout_writer.interface,
        .timer_interval_ms = 1000,
        .file_watch_path = "main.lua",
    });

    log.debug("frame rendered", .{});
}

fn selectedBackend(init: std.process.Init) keywork.BackendKind {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--wayland")) return .wayland_shm;
        if (std.mem.eql(u8, arg, "--backend=shm")) return .wayland_shm;
        if (std.mem.eql(u8, arg, "--backend=vulkan")) return .vulkan;
    }
    return .log;
}
