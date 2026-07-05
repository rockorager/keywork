//! Native Zig example consuming libkeywork as an application dependency.

const std = @import("std");
const keywork = @import("libkeywork");

const AppContext = keywork.AppContext;
const AppHost = keywork.AppHost;
const BuildScope = keywork.BuildScope;
const Widget = keywork.Widget;
const widgets = keywork.widgets;

const NativeApp = struct {
    count: u32 = 0,

    fn host(self: *NativeApp) AppHost {
        return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
    }

    fn buildWidget(ptr: *anyopaque, scope: *BuildScope, context: AppContext) !Widget {
        const self: *NativeApp = @ptrCast(@alignCast(ptr));
        const allocator = scope.allocator;
        const count_label = try std.fmt.allocPrint(allocator, "Count: {d}", .{self.count});
        const scheme_label = try std.fmt.allocPrint(allocator, "color scheme: {s}", .{context.color_scheme});
        const input_label = if (context.input_text.len == 0) "text input is empty" else context.input_text;

        const button = try widgets.actionButton(allocator, "increment", "Increment", "increment");
        const input = widgets.textInput("native-input", context.input_text, "Type here");
        const children = [_]Widget{
            widgets.coloredText("Native Zig libkeywork example", keywork.colors.accent),
            widgets.text(count_label),
            input,
            widgets.text(input_label),
            widgets.text(scheme_label),
            button,
        };
        const column = try widgets.column(allocator, &children, 12);
        const action_bindings = [_]Widget.ActionBinding{.{ .id = "increment", .callback = .{ .ptr = self, .call_fn = increment } }};
        const actions = try widgets.actions(allocator, &action_bindings, column);
        return widgets.padding(allocator, keywork.EdgeInsets.all(24), actions);
    }

    fn increment(ptr: *anyopaque) !void {
        const self: *NativeApp = @ptrCast(@alignCast(ptr));
        self.count += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var app: NativeApp = .{};
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    try keywork.run(allocator, app.host(), .{
        .title = "Keywork native Zig example",
        .width = 640,
        .height = 480,
        .backend = selectedBackend(init),
        .log_writer = &stdout_writer.interface,
    });
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
