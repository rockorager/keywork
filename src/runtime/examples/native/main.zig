const std = @import("std");
const keywork_loop = @import("keywork-loop");
const keywork_runtime = @import("keywork-runtime");
const keywork_ui = @import("keywork-ui");

const ExampleApp = struct {
    fn buildWidget(_: *anyopaque, scope: *keywork_ui.BuildScope, _: keywork_ui.AppContext) !keywork_ui.Widget {
        const label = try keywork_ui.Widget.alloc(
            scope.allocator,
            keywork_ui.widgets.text("Hello from native Keywork"),
        );
        const centered = try keywork_ui.Widget.alloc(scope.allocator, .{
            .center = .{ .child = label },
        });
        return .{ .box = .{
            .child = centered,
            .background = keywork_ui.colors.surface_light,
        } };
    }
};

pub fn main(init: std.process.Init) !void {
    var event_loop = try keywork_loop.EventLoop.init(init.gpa);
    defer event_loop.deinit();

    var app: ExampleApp = .{};
    const host: keywork_ui.AppHost = .{
        .ptr = &app,
        .vtable = &.{ .build_widget = ExampleApp.buildWidget },
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    try keywork_runtime.run(init.gpa, &event_loop, host, .{
        .title = "Native Keywork Example",
        .app_id = "dev.keywork.NativeExample",
        .width = 640,
        .height = 480,
        .backend = .wayland_shm,
        .log_writer = &stdout_writer.interface,
    });
}
