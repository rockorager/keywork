//! Minimal C ABI for libkeywork.

const std = @import("std");
const keywork = @import("libkeywork");

const TextApp = struct {
    text: []const u8,

    fn host(self: *TextApp) keywork.AppHost {
        return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
    }

    fn buildWidget(ptr: *anyopaque, allocator: std.mem.Allocator, _: keywork.AppContext) !keywork.Widget {
        const self: *TextApp = @ptrCast(@alignCast(ptr));
        const child = keywork.widgets.coloredText(self.text, keywork.colors.ink);
        return keywork.widgets.padding(allocator, keywork.EdgeInsets.all(24), child);
    }
};

pub const KeyworkRunTextOptions = extern struct {
    title: ?[*:0]const u8 = null,
    text: ?[*:0]const u8 = null,
    backend: c_int = 0,
    width: f32 = 640,
    height: f32 = 480,
};

pub export fn keywork_run_text(options: ?*const KeyworkRunTextOptions) callconv(.c) c_int {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const opts = options orelse &KeyworkRunTextOptions{};
    var app: TextApp = .{ .text = cString(opts.text, "Hello from libkeywork") };
    keywork.run(allocator, app.host(), .{
        .title = cStringZ(opts.title, "Keywork C example"),
        .width = if (opts.width > 0) opts.width else 640,
        .height = if (opts.height > 0) opts.height else 480,
        .backend = backendKind(opts.backend),
        .timer_interval_ms = null,
    }) catch |err| return errorCode(err);
    return 0;
}

fn cString(value: ?[*:0]const u8, fallback: []const u8) []const u8 {
    const ptr = value orelse return fallback;
    return std.mem.span(ptr);
}

fn cStringZ(value: ?[*:0]const u8, fallback: [:0]const u8) [:0]const u8 {
    const ptr = value orelse return fallback;
    return std.mem.span(ptr);
}

fn backendKind(value: c_int) keywork.BackendKind {
    return switch (value) {
        1 => .wayland_shm,
        2 => .vulkan,
        else => .log,
    };
}

fn errorCode(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => 2,
        error.InvalidFrameSize => 3,
        else => 1,
    };
}
