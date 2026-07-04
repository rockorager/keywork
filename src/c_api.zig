//! Minimal C ABI for libkeywork.

const std = @import("std");
const keywork = @import("libkeywork");

pub const KeyworkBuild = opaque {};
pub const KeyworkWidget = opaque {};

pub const KeyworkContext = extern struct {
    input_text: [*:0]const u8,
    focused_input_id: ?[*:0]const u8,
    window_width: f32,
    window_height: f32,
    color_scheme: [*:0]const u8,
};

pub const KeyworkAppVTable = extern struct {
    build: ?*const fn (userdata: ?*anyopaque, build: *KeyworkBuild, context: *const KeyworkContext) callconv(.c) ?*KeyworkWidget = null,
    click: ?*const fn (userdata: ?*anyopaque, id: [*:0]const u8) callconv(.c) c_int = null,
    timer: ?*const fn (userdata: ?*anyopaque, expirations: u64) callconv(.c) c_int = null,
};

pub const KeyworkClickCallback = *const fn (userdata: ?*anyopaque) callconv(.c) void;

pub const KeyworkRunOptions = extern struct {
    title: ?[*:0]const u8 = null,
    backend: c_int = 0,
    width: f32 = 640,
    height: f32 = 480,
    timer_interval_ms: u64 = 0,
};

pub const KeyworkRunTextOptions = extern struct {
    title: ?[*:0]const u8 = null,
    text: ?[*:0]const u8 = null,
    backend: c_int = 0,
    width: f32 = 640,
    height: f32 = 480,
};

const BuildScope = struct {
    allocator: std.mem.Allocator,
};

const ClickCallback = struct {
    callback: KeyworkClickCallback,
    userdata: ?*anyopaque,

    fn keyworkCallback(self: *ClickCallback) keywork.Widget.Callback {
        return .{ .ptr = self, .call_fn = call };
    }

    fn call(ptr: *anyopaque) !void {
        const self: *ClickCallback = @ptrCast(@alignCast(ptr));
        self.callback(self.userdata);
    }
};

const CApp = struct {
    vtable: KeyworkAppVTable,
    userdata: ?*anyopaque,

    fn host(self: *CApp) keywork.AppHost {
        return .{ .ptr = self, .vtable = &.{
            .build_widget = buildWidget,
            .click = click,
            .timer = timer,
        } };
    }

    fn buildWidget(ptr: *anyopaque, allocator: std.mem.Allocator, context: keywork.AppContext) !keywork.Widget {
        const self: *CApp = @ptrCast(@alignCast(ptr));
        const build_fn = self.vtable.build orelse return error.MissingBuildCallback;
        var scope: BuildScope = .{ .allocator = allocator };
        const c_context = try makeContext(allocator, context);
        const handle = build_fn(self.userdata, buildHandle(&scope), &c_context) orelse return error.BuildCallbackFailed;
        return widgetFromHandle(handle).*;
    }

    fn click(ptr: *anyopaque, id: []const u8) !bool {
        const self: *CApp = @ptrCast(@alignCast(ptr));
        const click_fn = self.vtable.click orelse return false;
        const id_z = try std.heap.c_allocator.dupeZ(u8, id);
        defer std.heap.c_allocator.free(id_z);
        return click_fn(self.userdata, id_z.ptr) != 0;
    }

    fn timer(ptr: *anyopaque, expirations: u64) !bool {
        const self: *CApp = @ptrCast(@alignCast(ptr));
        const timer_fn = self.vtable.timer orelse return false;
        return timer_fn(self.userdata, expirations) != 0;
    }
};

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

pub export fn keywork_run_app(
    options: ?*const KeyworkRunOptions,
    vtable: ?*const KeyworkAppVTable,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const app_vtable = vtable orelse return 4;
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const opts = options orelse &KeyworkRunOptions{};
    var app: CApp = .{ .vtable = app_vtable.*, .userdata = userdata };
    keywork.run(allocator, app.host(), .{
        .title = cStringZ(opts.title, "Keywork C app"),
        .width = if (opts.width > 0) opts.width else 640,
        .height = if (opts.height > 0) opts.height else 480,
        .backend = backendKind(opts.backend),
        .timer_interval_ms = if (opts.timer_interval_ms == 0) null else opts.timer_interval_ms,
    }) catch |err| return errorCode(err);
    return 0;
}

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

pub export fn keywork_text(build: ?*KeyworkBuild, value: ?[*:0]const u8) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    return makeWidget(scope, keywork.widgets.text(copyString(scope.allocator, value, "") catch return null));
}

pub export fn keywork_colored_text(build: ?*KeyworkBuild, value: ?[*:0]const u8, argb: u32) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    return makeWidget(scope, keywork.widgets.coloredText(
        copyString(scope.allocator, value, "") catch return null,
        colorFromArgb(argb),
    ));
}

pub export fn keywork_text_input(
    build: ?*KeyworkBuild,
    id: ?[*:0]const u8,
    value: ?[*:0]const u8,
    placeholder: ?[*:0]const u8,
    focused: c_int,
) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    return makeWidget(scope, keywork.widgets.textInput(
        copyString(scope.allocator, id, "") catch return null,
        copyString(scope.allocator, value, "") catch return null,
        copyString(scope.allocator, placeholder, "") catch return null,
        focused != 0,
    ));
}

pub export fn keywork_box(build: ?*KeyworkBuild, child: ?*KeyworkWidget, argb: u32) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    return makeWidget(scope, keywork.widgets.box(scope.allocator, child_widget.*, colorFromArgb(argb)) catch return null);
}

pub export fn keywork_clickable(build: ?*KeyworkBuild, id: ?[*:0]const u8, child: ?*KeyworkWidget) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    return makeWidget(scope, keywork.widgets.clickable(
        scope.allocator,
        copyString(scope.allocator, id, "") catch return null,
        child_widget.*,
    ) catch return null);
}

pub export fn keywork_clickable_callback(
    build: ?*KeyworkBuild,
    child: ?*KeyworkWidget,
    callback: ?KeyworkClickCallback,
    userdata: ?*anyopaque,
) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    const callback_fn = callback orelse return null;
    const callback_state = scope.allocator.create(ClickCallback) catch return null;
    callback_state.* = .{ .callback = callback_fn, .userdata = userdata };
    const child_copy = keywork.Widget.alloc(scope.allocator, child_widget.*) catch return null;
    return makeWidget(scope, .{ .clickable = .{
        .id = "",
        .child = child_copy,
        .on_click = callback_state.keyworkCallback(),
    } });
}

pub export fn keywork_padding(build: ?*KeyworkBuild, inset: f32, child: ?*KeyworkWidget) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    return makeWidget(scope, keywork.widgets.padding(scope.allocator, keywork.EdgeInsets.all(inset), child_widget.*) catch return null);
}

pub export fn keywork_center(build: ?*KeyworkBuild, child: ?*KeyworkWidget) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    return makeWidget(scope, keywork.widgets.center(scope.allocator, child_widget.*) catch return null);
}

pub export fn keywork_keyed_string(build: ?*KeyworkBuild, key: ?[*:0]const u8, child: ?*KeyworkWidget) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    return makeWidget(scope, keywork.widgets.keyed(
        scope.allocator,
        .{ .string = copyString(scope.allocator, key, "") catch return null },
        child_widget.*,
    ) catch return null);
}

pub export fn keywork_keyed_int(build: ?*KeyworkBuild, key: u64, child: ?*KeyworkWidget) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    return makeWidget(scope, keywork.widgets.keyed(scope.allocator, .{ .integer = key }, child_widget.*) catch return null);
}

pub export fn keywork_column(
    build: ?*KeyworkBuild,
    children: ?[*]const ?*KeyworkWidget,
    child_count: usize,
    gap: f32,
) callconv(.c) ?*KeyworkWidget {
    return linear(build, children, child_count, gap, .column);
}

pub export fn keywork_row(
    build: ?*KeyworkBuild,
    children: ?[*]const ?*KeyworkWidget,
    child_count: usize,
    gap: f32,
) callconv(.c) ?*KeyworkWidget {
    return linear(build, children, child_count, gap, .row);
}

fn linear(
    build: ?*KeyworkBuild,
    children: ?[*]const ?*KeyworkWidget,
    child_count: usize,
    gap: f32,
    comptime direction: enum { row, column },
) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    if (child_count > 0 and children == null) return null;

    const child_widgets = scope.allocator.alloc(keywork.Widget, child_count) catch return null;
    const child_handles = if (children) |ptr| ptr[0..child_count] else &[_]?*KeyworkWidget{};
    for (child_handles, 0..) |child, index| {
        const child_widget = widgetFromMaybeHandle(child) orelse return null;
        child_widgets[index] = child_widget.*;
    }
    const widget = switch (direction) {
        .row => keywork.widgets.row(scope.allocator, child_widgets, gap),
        .column => keywork.widgets.column(scope.allocator, child_widgets, gap),
    } catch return null;
    return makeWidget(scope, widget);
}

fn makeContext(allocator: std.mem.Allocator, context: keywork.AppContext) !KeyworkContext {
    const input_text = try allocator.dupeZ(u8, context.input_text);
    const color_scheme = try allocator.dupeZ(u8, context.color_scheme);
    const focused_input_id = if (context.focused_input_id) |id| (try allocator.dupeZ(u8, id)).ptr else null;
    return .{
        .input_text = input_text.ptr,
        .focused_input_id = focused_input_id,
        .window_width = context.window_width,
        .window_height = context.window_height,
        .color_scheme = color_scheme.ptr,
    };
}

fn buildHandle(scope: *BuildScope) *KeyworkBuild {
    return @ptrCast(scope);
}

fn buildScope(handle: ?*KeyworkBuild) ?*BuildScope {
    return @ptrCast(@alignCast(handle orelse return null));
}

fn widgetHandle(widget: *keywork.Widget) *KeyworkWidget {
    return @ptrCast(widget);
}

fn widgetFromHandle(handle: *KeyworkWidget) *keywork.Widget {
    return @ptrCast(@alignCast(handle));
}

fn widgetFromMaybeHandle(handle: ?*KeyworkWidget) ?*keywork.Widget {
    return widgetFromHandle(handle orelse return null);
}

fn makeWidget(scope: *BuildScope, widget: keywork.Widget) ?*KeyworkWidget {
    const result = keywork.Widget.alloc(scope.allocator, widget) catch return null;
    return widgetHandle(result);
}

fn copyString(allocator: std.mem.Allocator, value: ?[*:0]const u8, fallback: []const u8) ![]const u8 {
    return try allocator.dupe(u8, cString(value, fallback));
}

fn cString(value: ?[*:0]const u8, fallback: []const u8) []const u8 {
    const ptr = value orelse return fallback;
    return std.mem.span(ptr);
}

fn cStringZ(value: ?[*:0]const u8, fallback: [:0]const u8) [:0]const u8 {
    const ptr = value orelse return fallback;
    return std.mem.span(ptr);
}

fn colorFromArgb(argb: u32) keywork.Color {
    return @bitCast(argb);
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
        error.MissingBuildCallback => 4,
        error.BuildCallbackFailed => 5,
        else => 1,
    };
}
