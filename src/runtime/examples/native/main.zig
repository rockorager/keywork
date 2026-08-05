const std = @import("std");
const keywork_loop = @import("keywork-loop");
const keywork_runtime = @import("keywork-runtime");
const keywork_ui = @import("keywork-ui");

const canvas_width = 560;
const canvas_height = 320;

fn drawDemo(canvas: *keywork_runtime.SharedPixelBuffer) !void {
    const write = try canvas.beginWrite();
    const destination = std.mem.bytesAsSlice(u32, write.pointer[0..write.byte_len]);
    for (0..canvas_height) |y| {
        for (0..canvas_width) |x| {
            const checker: u8 = if (((x / 32) + (y / 32)) % 2 == 0) 20 else 0;
            const red: u8 = @intCast(24 + @as(u32, @intCast(x)) * 96 / canvas_width + checker);
            const green: u8 = @intCast(32 + @as(u32, @intCast(y)) * 112 / canvas_height + checker);
            const blue: u8 = @intCast(88 + @as(u32, @intCast(x)) * 72 / canvas_width);
            destination[y * canvas_width + x] = @bitCast(keywork_ui.Color.argb(255, red, green, blue));
        }
    }
    _ = try canvas.commit(&.{canvas.fullRect()});
}

const ExampleApp = struct {
    canvas: *keywork_runtime.SharedPixelBuffer,

    fn buildWidget(ptr: *anyopaque, scope: *keywork_ui.BuildScope, _: keywork_ui.AppContext) !keywork_ui.Widget {
        const self: *ExampleApp = @ptrCast(@alignCast(ptr));
        const canvas = try keywork_ui.Widget.alloc(scope.allocator, try self.canvas.widget(scope.allocator, null));
        const framed_canvas: keywork_ui.Widget = .{ .box = .{
            .child = canvas,
            .border = keywork_ui.colors.neutral_stroke1_light,
            .border_width = 1,
            .radius = keywork_ui.scale.radius(2),
        } };
        const children = [_]keywork_ui.Widget{
            .{ .text = .{ .value = "Ref-counted SHM canvas", .font_size = 20 } },
            .{ .text = .{ .value = "The widget retains a memfd mapping and consumes producer-reported damage without copying source pixels." } },
            framed_canvas,
        };
        const content = try keywork_ui.widgets.column(scope.allocator, &children, keywork_ui.scale.space(3));
        const padded = try keywork_ui.Widget.alloc(
            scope.allocator,
            try keywork_ui.widgets.padding(scope.allocator, keywork_ui.EdgeInsets.all(keywork_ui.scale.space(4)), content),
        );
        return .{ .box = .{
            .child = padded,
            .background = keywork_ui.colors.surface_light,
        } };
    }
};

pub fn main(init: std.process.Init) !void {
    var event_loop = try keywork_loop.EventLoop.init(init.gpa);
    defer event_loop.deinit();

    const canvas = try keywork_runtime.SharedPixelBuffer.create(init.gpa, canvas_width, canvas_height, .xrgb8888);
    defer canvas.release();
    try drawDemo(canvas);
    var app: ExampleApp = .{ .canvas = canvas };
    const host: keywork_ui.AppHost = .{
        .ptr = &app,
        .vtable = &.{ .build_widget = ExampleApp.buildWidget },
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    try keywork_runtime.run(init.gpa, &event_loop, host, .{
        .title = "Native Keywork SHM Canvas",
        .app_id = "dev.keywork.NativeExample",
        .width = 640,
        .height = 480,
        .backend = .wayring_shm,
        .log_writer = &stdout_writer.interface,
    });
}
