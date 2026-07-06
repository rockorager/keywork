//! Minimal C ABI for libkeywork.

const std = @import("std");
const keywork = @import("libkeywork");

const linux = std.os.linux;

pub const KeyworkBuild = opaque {};
pub const KeyworkWidget = opaque {};
pub const KeyworkEventLoop = opaque {};
pub const KeyworkRuntime = opaque {};
pub const KeyworkTimer = opaque {};

pub const KeyworkContext = extern struct {
    window_width: f32,
    window_height: f32,
    color_scheme: [*:0]const u8,
};

pub const KeyworkAppVTable = extern struct {
    build: ?*const fn (userdata: ?*anyopaque, build: *KeyworkBuild, context: *const KeyworkContext) callconv(.c) ?*KeyworkWidget = null,
    install_event_sources: ?*const fn (userdata: ?*anyopaque, loop: *KeyworkEventLoop, runtime: *KeyworkRuntime) callconv(.c) c_int = null,
};

pub const KeyworkClickCallback = *const fn (userdata: ?*anyopaque) callconv(.c) void;
pub const KeyworkFdCallback = *const fn (userdata: ?*anyopaque, loop: *KeyworkEventLoop, events: u32) callconv(.c) c_int;
pub const KeyworkTimerCallback = *const fn (userdata: ?*anyopaque, loop: *KeyworkEventLoop, expirations: u64) callconv(.c) c_int;
pub const KeyworkTextChangeCallback = *const fn (userdata: ?*anyopaque, text: [*:0]const u8, len: usize) callconv(.c) void;
pub const KeyworkItemBuilderCallback = *const fn (userdata: ?*anyopaque, build: *KeyworkBuild, index: usize) callconv(.c) ?*KeyworkWidget;

pub const KeyworkSize = extern struct {
    width: f32,
    height: f32,
};

pub const KeyworkRect = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const KeyworkConstraints = extern struct {
    max_width: f32,
    max_height: f32,
};

pub const KeyworkDisplayList = opaque {};

pub const KeyworkRenderObjectVTable = extern struct {
    layout: ?*const fn (userdata: ?*anyopaque, constraints: KeyworkConstraints) callconv(.c) KeyworkSize = null,
    paint: ?*const fn (userdata: ?*anyopaque, display_list: *KeyworkDisplayList, rect: KeyworkRect) callconv(.c) c_int = null,
    destroy: ?*const fn (userdata: ?*anyopaque) callconv(.c) void = null,
};

pub const KeyworkBuildContext = extern struct {
    constraints: KeyworkConstraints,
};

pub const KeyworkStatefulVTable = extern struct {
    create_state: ?*const fn (userdata: ?*anyopaque) callconv(.c) ?*anyopaque = null,
    update: ?*const fn (userdata: ?*anyopaque, state: *anyopaque, context: *const KeyworkBuildContext) callconv(.c) c_int = null,
    build: ?*const fn (userdata: ?*anyopaque, state: *anyopaque, build: *KeyworkBuild, context: *const KeyworkBuildContext) callconv(.c) ?*KeyworkWidget = null,
    destroy_state: ?*const fn (userdata: ?*anyopaque, state: *anyopaque) callconv(.c) void = null,
};

pub const KeyworkElementVTable = extern struct {
    build: ?*const fn (userdata: ?*anyopaque, build: *KeyworkBuild, context: *const KeyworkBuildContext) callconv(.c) ?*KeyworkWidget = null,
    destroy: ?*const fn (userdata: ?*anyopaque) callconv(.c) void = null,
};

pub const KeyworkRunOptions = extern struct {
    title: ?[*:0]const u8 = null,
    backend: c_int = 0,
    width: f32 = 640,
    height: f32 = 480,
    layer_shell: c_int = 0,
    layer_namespace: ?[*:0]const u8 = null,
    layer: c_int = 2,
    layer_anchors: u32 = 0,
    layer_exclusive_zone: i32 = 0,
    layer_margin_top: i32 = 0,
    layer_margin_right: i32 = 0,
    layer_margin_bottom: i32 = 0,
    layer_margin_left: i32 = 0,
    layer_keyboard_interactivity: c_int = 0,
};

pub const KeyworkRunTextOptions = extern struct {
    title: ?[*:0]const u8 = null,
    text: ?[*:0]const u8 = null,
    backend: c_int = 0,
    width: f32 = 640,
    height: f32 = 480,
    layer_shell: c_int = 0,
    layer_namespace: ?[*:0]const u8 = null,
    layer: c_int = 2,
    layer_anchors: u32 = 0,
    layer_exclusive_zone: i32 = 0,
    layer_margin_top: i32 = 0,
    layer_margin_right: i32 = 0,
    layer_margin_bottom: i32 = 0,
    layer_margin_left: i32 = 0,
    layer_keyboard_interactivity: c_int = 0,
};

const CBuildScope = struct {
    scope: *keywork.BuildScope,
};

const ClickCallback = struct {
    callback: KeyworkClickCallback,
    userdata: ?*anyopaque,

    fn keyworkCallback(self: *ClickCallback) keywork.Widget.Callback {
        return .{
            .ptr = self,
            .call_fn = call,
            .clone_fn = clone,
            .destroy_fn = destroy,
        };
    }

    fn call(ptr: *anyopaque) !void {
        const self: *ClickCallback = @ptrCast(@alignCast(ptr));
        self.callback(self.userdata);
    }

    fn clone(allocator: std.mem.Allocator, ptr: *anyopaque) !*anyopaque {
        const self: *ClickCallback = @ptrCast(@alignCast(ptr));
        const result = try allocator.create(ClickCallback);
        result.* = self.*;
        return result;
    }

    fn destroy(allocator: std.mem.Allocator, ptr: *anyopaque) void {
        const self: *ClickCallback = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

const CTextChangeCallback = struct {
    callback: KeyworkTextChangeCallback,
    userdata: ?*anyopaque,

    fn textChangeCallback(self: *CTextChangeCallback) keywork.Widget.TextChangeCallback {
        return .{
            .ptr = self,
            .call_fn = call,
            .clone_fn = clone,
            .destroy_fn = destroy,
        };
    }

    fn call(ptr: *anyopaque, text: []const u8) !void {
        const self: *CTextChangeCallback = @ptrCast(@alignCast(ptr));
        // The editing buffer is not null-terminated; C callers expect a
        // C string, so hand out a terminated copy for the callback's
        // duration only.
        const copy = try std.heap.c_allocator.dupeZ(u8, text);
        defer std.heap.c_allocator.free(copy);
        self.callback(self.userdata, copy.ptr, text.len);
    }

    fn clone(allocator: std.mem.Allocator, ptr: *anyopaque) !*anyopaque {
        const self: *CTextChangeCallback = @ptrCast(@alignCast(ptr));
        const result = try allocator.create(CTextChangeCallback);
        result.* = self.*;
        return result;
    }

    fn destroy(allocator: std.mem.Allocator, ptr: *anyopaque) void {
        const self: *CTextChangeCallback = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

const CItemBuilder = struct {
    callback: KeyworkItemBuilderCallback,
    userdata: ?*anyopaque,

    fn itemBuilder(self: *const CItemBuilder) keywork.Widget.ItemBuilder {
        return .{
            .ptr = self,
            .build_fn = buildItem,
            .clone_fn = clone,
            .destroy_fn = destroy,
        };
    }

    fn buildItem(ptr: *const anyopaque, scope: *keywork.BuildScope, index: usize) !keywork.Widget {
        const self: *const CItemBuilder = @ptrCast(@alignCast(ptr));
        var c_scope: CBuildScope = .{ .scope = scope };
        const handle = self.callback(self.userdata, buildHandle(&c_scope), index) orelse return error.ListItemBuildFailed;
        return widgetFromHandle(handle).*;
    }

    fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
        const self: *const CItemBuilder = @ptrCast(@alignCast(ptr));
        const result = try allocator.create(CItemBuilder);
        result.* = self.*;
        return result;
    }

    fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *const CItemBuilder = @ptrCast(@alignCast(ptr));
        allocator.destroy(@constCast(self));
    }
};

const CDisplayList = struct {
    allocator: std.mem.Allocator,
    display_list: *keywork.DisplayList,
};

const CRenderObject = struct {
    vtable: KeyworkRenderObjectVTable,
    userdata: ?*anyopaque,

    const keywork_vtable: keywork.Widget.RenderObject.VTable = .{
        .layout = layout,
        .paint = paint,
    };

    fn keyworkRenderObject(self: *const CRenderObject) keywork.Widget.RenderObject {
        return .{
            .ptr = self,
            .vtable = &keywork_vtable,
            .clone_fn = clone,
            .destroy_fn = destroy,
        };
    }

    fn layout(ptr: *const anyopaque, context: keywork.Widget.RenderObject.LayoutContext) !keywork.Size {
        const self: *const CRenderObject = @ptrCast(@alignCast(ptr));
        const layout_fn = self.vtable.layout orelse return error.MissingRenderObjectLayout;
        const result = layout_fn(self.userdata, constraintsToC(context.constraints));
        return .{ .width = result.width, .height = result.height };
    }

    fn paint(ptr: *const anyopaque, context: keywork.Widget.RenderObject.PaintContext) !void {
        const self: *const CRenderObject = @ptrCast(@alignCast(ptr));
        const paint_fn = self.vtable.paint orelse return error.MissingRenderObjectPaint;
        var display_list: CDisplayList = .{ .allocator = context.allocator, .display_list = context.display_list };
        if (paint_fn(self.userdata, displayListHandle(&display_list), rectToC(context.rect)) == 0) {
            return error.RenderObjectPaintFailed;
        }
    }

    fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
        const self: *const CRenderObject = @ptrCast(@alignCast(ptr));
        const result = try allocator.create(CRenderObject);
        result.* = self.*;
        return result;
    }

    fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *const CRenderObject = @ptrCast(@alignCast(ptr));
        if (self.vtable.destroy) |destroy_fn| destroy_fn(self.userdata);
        allocator.destroy(@constCast(self));
    }
};

const CStateful = struct {
    vtable: KeyworkStatefulVTable,
    userdata: ?*anyopaque,

    const keywork_vtable: keywork.Widget.Stateful.VTable = .{
        .create_state = createState,
        .update = update,
        .build = build,
        .destroy_state = destroyState,
    };

    fn keyworkStateful(self: *const CStateful) keywork.Widget.Stateful {
        return .{
            .ptr = self,
            .vtable = &keywork_vtable,
            .clone_fn = clone,
            .destroy_fn = destroy,
        };
    }

    fn createState(ptr: *const anyopaque, allocator: std.mem.Allocator) !*anyopaque {
        _ = allocator;
        const self: *const CStateful = @ptrCast(@alignCast(ptr));
        const create_fn = self.vtable.create_state orelse return error.MissingStatefulCreateState;
        return create_fn(self.userdata) orelse error.StatefulCreateStateFailed;
    }

    fn update(ptr: *const anyopaque, state: *anyopaque, allocator: std.mem.Allocator, context: keywork.Widget.BuildContext) !void {
        _ = allocator;
        const self: *const CStateful = @ptrCast(@alignCast(ptr));
        const update_fn = self.vtable.update orelse return;
        const c_context: KeyworkBuildContext = .{ .constraints = constraintsToC(context.constraints) };
        if (update_fn(self.userdata, state, &c_context) == 0) return error.StatefulUpdateFailed;
    }

    fn build(ptr: *const anyopaque, state: *anyopaque, scope: *keywork.BuildScope, context: keywork.Widget.BuildContext) !keywork.Widget {
        const self: *const CStateful = @ptrCast(@alignCast(ptr));
        const build_fn = self.vtable.build orelse return error.MissingStatefulBuild;
        var c_scope: CBuildScope = .{ .scope = scope };
        const c_context: KeyworkBuildContext = .{ .constraints = constraintsToC(context.constraints) };
        const handle = build_fn(self.userdata, state, buildHandle(&c_scope), &c_context) orelse return error.StatefulBuildFailed;
        return widgetFromHandle(handle).*;
    }

    fn destroyState(ptr: *const anyopaque, state: *anyopaque, allocator: std.mem.Allocator) void {
        _ = allocator;
        const self: *const CStateful = @ptrCast(@alignCast(ptr));
        if (self.vtable.destroy_state) |destroy_fn| destroy_fn(self.userdata, state);
    }

    fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
        const self: *const CStateful = @ptrCast(@alignCast(ptr));
        const result = try allocator.create(CStateful);
        result.* = self.*;
        return result;
    }

    fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *const CStateful = @ptrCast(@alignCast(ptr));
        allocator.destroy(@constCast(self));
    }
};

const CElement = struct {
    vtable: KeyworkElementVTable,
    userdata: ?*anyopaque,

    const keywork_vtable: keywork.Widget.CustomElement.VTable = .{ .build = build };

    fn keyworkElement(self: *const CElement) keywork.Widget.CustomElement {
        return .{
            .ptr = self,
            .vtable = &keywork_vtable,
            .clone_fn = clone,
            .destroy_fn = destroy,
        };
    }

    fn build(ptr: *const anyopaque, allocator: std.mem.Allocator, scope: *keywork.BuildScope, context: keywork.Widget.BuildContext) !keywork.Element {
        const self: *const CElement = @ptrCast(@alignCast(ptr));
        const build_fn = self.vtable.build orelse return error.MissingElementBuild;
        var c_scope: CBuildScope = .{ .scope = scope };
        const c_context: KeyworkBuildContext = .{ .constraints = constraintsToC(context.constraints) };
        const handle = build_fn(self.userdata, buildHandle(&c_scope), &c_context) orelse return error.ElementBuildFailed;
        const widget = widgetFromHandle(handle);
        return keywork.buildElementTreeScoped(allocator, scope, widget, context.constraints);
    }

    fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
        const self: *const CElement = @ptrCast(@alignCast(ptr));
        const result = try allocator.create(CElement);
        result.* = self.*;
        return result;
    }

    fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
        const self: *const CElement = @ptrCast(@alignCast(ptr));
        if (self.vtable.destroy) |destroy_fn| destroy_fn(self.userdata);
        allocator.destroy(@constCast(self));
    }
};

const CFdSource = struct {
    callback: KeyworkFdCallback,
    userdata: ?*anyopaque,

    fn eventLoopCallback(ctx: *anyopaque, loop: *keywork.event_loop.EventLoop, events: u32) !void {
        const self: *CFdSource = @ptrCast(@alignCast(ctx));
        if (self.callback(self.userdata, eventLoopHandle(loop), eventsToC(events)) == 0) return error.CFdCallbackFailed;
    }

    fn destroy(allocator: std.mem.Allocator, ctx: *anyopaque) void {
        const self: *CFdSource = @ptrCast(@alignCast(ctx));
        allocator.destroy(self);
    }
};

const CTimerSource = struct {
    callback: KeyworkTimerCallback,
    userdata: ?*anyopaque,

    fn eventLoopCallback(ctx: *anyopaque, loop: *keywork.event_loop.EventLoop, expirations: u64) !void {
        const self: *CTimerSource = @ptrCast(@alignCast(ctx));
        if (self.callback(self.userdata, eventLoopHandle(loop), expirations) == 0) return error.CTimerCallbackFailed;
    }

    fn destroy(allocator: std.mem.Allocator, ctx: *anyopaque) void {
        const self: *CTimerSource = @ptrCast(@alignCast(ctx));
        allocator.destroy(self);
    }
};

const CApp = struct {
    vtable: KeyworkAppVTable,
    userdata: ?*anyopaque,

    fn host(self: *CApp) keywork.AppHost {
        return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
    }

    fn buildWidget(ptr: *anyopaque, scope: *keywork.BuildScope, context: keywork.AppContext) !keywork.Widget {
        const self: *CApp = @ptrCast(@alignCast(ptr));
        const build_fn = self.vtable.build orelse return error.MissingBuildCallback;
        var c_scope: CBuildScope = .{ .scope = scope };
        const c_context = try makeContext(scope.allocator, context);
        const handle = build_fn(self.userdata, buildHandle(&c_scope), &c_context) orelse return error.BuildCallbackFailed;
        return widgetFromHandle(handle).*;
    }

    fn installEventSources(ctx: ?*anyopaque, loop: *keywork.event_loop.EventLoop, runtime: *keywork.Runtime) !void {
        const self: *CApp = @ptrCast(@alignCast(ctx orelse return));
        const install_fn = self.vtable.install_event_sources orelse return;
        if (install_fn(self.userdata, eventLoopHandle(loop), runtimeHandle(runtime)) == 0) return error.EventSourceInstallFailed;
    }
};

const TextApp = struct {
    text: []const u8,

    fn host(self: *TextApp) keywork.AppHost {
        return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
    }

    fn buildWidget(ptr: *anyopaque, scope: *keywork.BuildScope, _: keywork.AppContext) !keywork.Widget {
        const self: *TextApp = @ptrCast(@alignCast(ptr));
        const child = keywork.widgets.coloredText(self.text, keywork.colors.ink);
        return keywork.widgets.padding(scope.allocator, keywork.EdgeInsets.all(24), child);
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
        .layer_shell = layerShellOptionsFromRunOptions(opts),
        .event_source_context = &app,
        .install_event_sources = if (app.vtable.install_event_sources != null) CApp.installEventSources else null,
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
        .layer_shell = layerShellOptionsFromRunTextOptions(opts),
    }) catch |err| return errorCode(err);
    return 0;
}

pub export fn keywork_loop_add_fd(
    loop_handle: ?*KeyworkEventLoop,
    fd: c_int,
    events: u32,
    callback: ?KeyworkFdCallback,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const loop = eventLoopFromHandle(loop_handle orelse return 0);
    const callback_fn = callback orelse return 0;
    const linux_events = eventsFromC(events) orelse return 0;
    const source = loop.allocator.create(CFdSource) catch return 0;
    source.* = .{ .callback = callback_fn, .userdata = userdata };
    loop.addFd(.{
        .fd = fd,
        .events = linux_events,
        .ctx = source,
        .callback = CFdSource.eventLoopCallback,
        .destroy_ctx = CFdSource.destroy,
    }) catch {
        loop.allocator.destroy(source);
        return 0;
    };
    return 1;
}

pub export fn keywork_loop_remove_fd(loop_handle: ?*KeyworkEventLoop, fd: c_int) callconv(.c) void {
    const loop = eventLoopFromHandle(loop_handle orelse return);
    loop.removeFd(fd);
}

pub export fn keywork_loop_add_timer(
    loop_handle: ?*KeyworkEventLoop,
    callback: ?KeyworkTimerCallback,
    userdata: ?*anyopaque,
) callconv(.c) ?*KeyworkTimer {
    const loop = eventLoopFromHandle(loop_handle orelse return null);
    const callback_fn = callback orelse return null;
    const source = loop.allocator.create(CTimerSource) catch return null;
    source.* = .{ .callback = callback_fn, .userdata = userdata };
    const timer = loop.addTimer(source, CTimerSource.eventLoopCallback) catch {
        loop.allocator.destroy(source);
        return null;
    };
    timer.destroy_ctx = CTimerSource.destroy;
    return timerHandle(timer);
}

pub export fn keywork_timer_arm(timer_handle: ?*KeyworkTimer, delay_ms: u64, interval_ms: u64) callconv(.c) c_int {
    const timer = timerFromHandle(timer_handle orelse return 0);
    timer.arm(delay_ms, interval_ms) catch return 0;
    return 1;
}

pub export fn keywork_timer_disarm(timer_handle: ?*KeyworkTimer) callconv(.c) void {
    const timer = timerFromHandle(timer_handle orelse return);
    timer.disarm();
}

pub export fn keywork_runtime_invalidate(runtime_handle: ?*KeyworkRuntime) callconv(.c) c_int {
    const runtime = runtimeFromHandle(runtime_handle orelse return 0);
    runtime.invalidate() catch return 0;
    return 1;
}

pub export fn keywork_runtime_invalidate_state(runtime_handle: ?*KeyworkRuntime) callconv(.c) c_int {
    const runtime = runtimeFromHandle(runtime_handle orelse return 0);
    runtime.invalidateState() catch return 0;
    return 1;
}

pub export fn keywork_loop_quit(loop_handle: ?*KeyworkEventLoop) callconv(.c) void {
    const loop = eventLoopFromHandle(loop_handle orelse return);
    loop.quit();
}

pub export fn keywork_text(build: ?*KeyworkBuild, value: ?[*:0]const u8) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const allocator = scope.scope.allocator;
    return makeWidget(scope, keywork.widgets.text(copyString(allocator, value, "") catch return null));
}

pub export fn keywork_colored_text(build: ?*KeyworkBuild, value: ?[*:0]const u8, argb: u32) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const allocator = scope.scope.allocator;
    return makeWidget(scope, keywork.widgets.coloredText(
        copyString(allocator, value, "") catch return null,
        colorFromArgb(argb),
    ));
}

pub export fn keywork_text_input(
    build: ?*KeyworkBuild,
    id: ?[*:0]const u8,
    value: ?[*:0]const u8,
    placeholder: ?[*:0]const u8,
) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const allocator = scope.scope.allocator;
    return makeWidget(scope, keywork.widgets.textInput(
        copyString(allocator, id, "") catch return null,
        copyString(allocator, value, "") catch return null,
        copyString(allocator, placeholder, "") catch return null,
    ));
}

pub export fn keywork_text_input_on_change(
    build: ?*KeyworkBuild,
    id: ?[*:0]const u8,
    value: ?[*:0]const u8,
    placeholder: ?[*:0]const u8,
    callback: ?KeyworkTextChangeCallback,
    userdata: ?*anyopaque,
) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const allocator = scope.scope.allocator;
    var widget = keywork.widgets.textInput(
        copyString(allocator, id, "") catch return null,
        copyString(allocator, value, "") catch return null,
        copyString(allocator, placeholder, "") catch return null,
    );
    if (callback) |callback_fn| {
        const callback_state = allocator.create(CTextChangeCallback) catch return null;
        callback_state.* = .{ .callback = callback_fn, .userdata = userdata };
        widget.text_input.on_change = callback_state.textChangeCallback();
    }
    return makeWidget(scope, widget);
}

pub export fn keywork_scroll(
    build: ?*KeyworkBuild,
    id: ?[*:0]const u8,
    child: ?*KeyworkWidget,
    axes: c_int,
) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    const allocator = scope.scope.allocator;
    const child_copy = keywork.Widget.alloc(allocator, child_widget.*) catch return null;
    const scroll_axes: keywork.Widget.ScrollAxes = switch (axes) {
        1 => .horizontal,
        2 => .both,
        else => .vertical,
    };
    return makeWidget(scope, .{ .scroll = .{
        .id = copyString(allocator, id, "") catch return null,
        .child = child_copy,
        .axes = scroll_axes,
    } });
}

pub export fn keywork_list(
    build: ?*KeyworkBuild,
    id: ?[*:0]const u8,
    item_count: usize,
    item_extent: f32,
    callback: ?KeyworkItemBuilderCallback,
    userdata: ?*anyopaque,
) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const callback_fn = callback orelse return null;
    if (!(item_extent > 0)) return null;
    const allocator = scope.scope.allocator;
    const builder = allocator.create(CItemBuilder) catch return null;
    builder.* = .{ .callback = callback_fn, .userdata = userdata };
    return makeWidget(scope, keywork.widgets.list(
        copyString(allocator, id, "") catch return null,
        item_count,
        item_extent,
        builder.itemBuilder(),
    ));
}

/// Pass a negative width or height to leave that axis unconstrained.
pub export fn keywork_sized(
    build: ?*KeyworkBuild,
    child: ?*KeyworkWidget,
    width: f32,
    height: f32,
) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    const allocator = scope.scope.allocator;
    return makeWidget(scope, keywork.widgets.sized(
        allocator,
        child_widget.*,
        if (width >= 0) width else null,
        if (height >= 0) height else null,
    ) catch return null);
}

pub export fn keywork_box(build: ?*KeyworkBuild, child: ?*KeyworkWidget, argb: u32) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    const allocator = scope.scope.allocator;
    return makeWidget(scope, keywork.widgets.box(allocator, child_widget.*, colorFromArgb(argb)) catch return null);
}

pub export fn keywork_clickable(
    build: ?*KeyworkBuild,
    id: ?[*:0]const u8,
    child: ?*KeyworkWidget,
    callback: ?KeyworkClickCallback,
    userdata: ?*anyopaque,
) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    const allocator = scope.scope.allocator;
    const on_click = if (callback) |callback_fn| blk: {
        const callback_state = allocator.create(ClickCallback) catch return null;
        callback_state.* = .{ .callback = callback_fn, .userdata = userdata };
        break :blk callback_state.keyworkCallback();
    } else null;
    const child_copy = keywork.Widget.alloc(allocator, child_widget.*) catch return null;
    return makeWidget(scope, .{ .clickable = .{
        .id = copyString(allocator, id, "") catch return null,
        .child = child_copy,
        .on_click = on_click,
    } });
}

pub export fn keywork_button(
    build: ?*KeyworkBuild,
    id: ?[*:0]const u8,
    label: ?[*:0]const u8,
    callback: ?KeyworkClickCallback,
    userdata: ?*anyopaque,
) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const allocator = scope.scope.allocator;
    const on_pressed = if (callback) |callback_fn| blk: {
        const callback_state = allocator.create(ClickCallback) catch return null;
        callback_state.* = .{ .callback = callback_fn, .userdata = userdata };
        break :blk callback_state.keyworkCallback();
    } else null;
    return makeWidget(scope, keywork.widgets.button(
        allocator,
        copyString(allocator, id, "") catch return null,
        copyString(allocator, label, "") catch return null,
        on_pressed,
    ) catch return null);
}

pub export fn keywork_render_object(
    build: ?*KeyworkBuild,
    vtable: ?*const KeyworkRenderObjectVTable,
    userdata: ?*anyopaque,
) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const render_vtable = vtable orelse return null;
    if (render_vtable.layout == null or render_vtable.paint == null) return null;
    const allocator = scope.scope.allocator;
    const render_object = allocator.create(CRenderObject) catch return null;
    render_object.* = .{ .vtable = render_vtable.*, .userdata = userdata };
    return makeWidget(scope, .{ .render_object = render_object.keyworkRenderObject() });
}

pub export fn keywork_display_list_fill_rect(
    display_list: ?*KeyworkDisplayList,
    rect: KeyworkRect,
    argb: u32,
) callconv(.c) c_int {
    const list = displayListFromHandle(display_list orelse return 0);
    list.display_list.fillRect(list.allocator, rectFromC(rect), colorFromArgb(argb)) catch return 0;
    return 1;
}

pub export fn keywork_stateful(
    build: ?*KeyworkBuild,
    vtable: ?*const KeyworkStatefulVTable,
    userdata: ?*anyopaque,
) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const stateful_vtable = vtable orelse return null;
    if (stateful_vtable.create_state == null or stateful_vtable.build == null) return null;
    const allocator = scope.scope.allocator;
    const stateful = allocator.create(CStateful) catch return null;
    stateful.* = .{ .vtable = stateful_vtable.*, .userdata = userdata };
    return makeWidget(scope, .{ .stateful = stateful.keyworkStateful() });
}

pub export fn keywork_element(
    build: ?*KeyworkBuild,
    vtable: ?*const KeyworkElementVTable,
    userdata: ?*anyopaque,
) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const element_vtable = vtable orelse return null;
    if (element_vtable.build == null) return null;
    const allocator = scope.scope.allocator;
    const element = allocator.create(CElement) catch return null;
    element.* = .{ .vtable = element_vtable.*, .userdata = userdata };
    return makeWidget(scope, .{ .element = element.keyworkElement() });
}

pub export fn keywork_padding(build: ?*KeyworkBuild, inset: f32, child: ?*KeyworkWidget) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    const allocator = scope.scope.allocator;
    return makeWidget(scope, keywork.widgets.padding(allocator, keywork.EdgeInsets.all(inset), child_widget.*) catch return null);
}

pub export fn keywork_center(build: ?*KeyworkBuild, child: ?*KeyworkWidget) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    const allocator = scope.scope.allocator;
    return makeWidget(scope, keywork.widgets.center(allocator, child_widget.*) catch return null);
}

pub export fn keywork_keyed_string(build: ?*KeyworkBuild, key: ?[*:0]const u8, child: ?*KeyworkWidget) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    const allocator = scope.scope.allocator;
    return makeWidget(scope, keywork.widgets.keyed(
        allocator,
        .{ .string = copyString(allocator, key, "") catch return null },
        child_widget.*,
    ) catch return null);
}

pub export fn keywork_keyed_int(build: ?*KeyworkBuild, key: u64, child: ?*KeyworkWidget) callconv(.c) ?*KeyworkWidget {
    const scope = buildScope(build) orelse return null;
    const child_widget = widgetFromMaybeHandle(child) orelse return null;
    const allocator = scope.scope.allocator;
    return makeWidget(scope, keywork.widgets.keyed(allocator, .{ .integer = key }, child_widget.*) catch return null);
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

    const allocator = scope.scope.allocator;
    const child_widgets = allocator.alloc(keywork.Widget, child_count) catch return null;
    const child_handles = if (children) |ptr| ptr[0..child_count] else &[_]?*KeyworkWidget{};
    for (child_handles, 0..) |child, index| {
        const child_widget = widgetFromMaybeHandle(child) orelse return null;
        child_widgets[index] = child_widget.*;
    }
    const widget = switch (direction) {
        .row => keywork.widgets.row(allocator, child_widgets, gap),
        .column => keywork.widgets.column(allocator, child_widgets, gap),
    } catch return null;
    return makeWidget(scope, widget);
}

fn makeContext(allocator: std.mem.Allocator, context: keywork.AppContext) !KeyworkContext {
    const color_scheme = try allocator.dupeZ(u8, context.color_scheme);
    return .{
        .window_width = context.window_width,
        .window_height = context.window_height,
        .color_scheme = color_scheme.ptr,
    };
}

fn buildHandle(scope: *CBuildScope) *KeyworkBuild {
    return @ptrCast(scope);
}

fn buildScope(handle: ?*KeyworkBuild) ?*CBuildScope {
    return @ptrCast(@alignCast(handle orelse return null));
}

fn displayListHandle(display_list: *CDisplayList) *KeyworkDisplayList {
    return @ptrCast(display_list);
}

fn displayListFromHandle(handle: *KeyworkDisplayList) *CDisplayList {
    return @ptrCast(@alignCast(handle));
}

fn eventLoopHandle(loop: *keywork.event_loop.EventLoop) *KeyworkEventLoop {
    return @ptrCast(loop);
}

fn eventLoopFromHandle(handle: *KeyworkEventLoop) *keywork.event_loop.EventLoop {
    return @ptrCast(@alignCast(handle));
}

fn runtimeHandle(runtime: *keywork.Runtime) *KeyworkRuntime {
    return @ptrCast(runtime);
}

fn runtimeFromHandle(handle: *KeyworkRuntime) *keywork.Runtime {
    return @ptrCast(@alignCast(handle));
}

fn timerHandle(timer: *keywork.event_loop.EventLoop.Timer) *KeyworkTimer {
    return @ptrCast(timer);
}

fn timerFromHandle(handle: *KeyworkTimer) *keywork.event_loop.EventLoop.Timer {
    return @ptrCast(@alignCast(handle));
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

fn makeWidget(scope: *CBuildScope, widget: keywork.Widget) ?*KeyworkWidget {
    const result = keywork.Widget.alloc(scope.scope.allocator, widget) catch return null;
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

fn eventsFromC(events: u32) ?u32 {
    var result: u32 = linux.EPOLL.HUP | linux.EPOLL.ERR;
    if (events & (1 << 0) != 0) result |= linux.EPOLL.IN;
    if (events & (1 << 1) != 0) result |= linux.EPOLL.OUT;
    if (result == (linux.EPOLL.HUP | linux.EPOLL.ERR)) return null;
    return result;
}

fn eventsToC(events: u32) u32 {
    var result: u32 = 0;
    if (events & linux.EPOLL.IN != 0) result |= 1 << 0;
    if (events & linux.EPOLL.OUT != 0) result |= 1 << 1;
    if (events & linux.EPOLL.HUP != 0) result |= 1 << 2;
    if (events & linux.EPOLL.ERR != 0) result |= 1 << 3;
    return result;
}

fn constraintsToC(constraints: keywork.Constraints) KeyworkConstraints {
    return .{ .max_width = constraints.max_width, .max_height = constraints.max_height };
}

fn rectToC(rect: keywork.Rect) KeyworkRect {
    return .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
}

fn rectFromC(rect: KeyworkRect) keywork.Rect {
    return .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
}

fn backendKind(value: c_int) keywork.BackendKind {
    return switch (value) {
        1 => .wayland_shm,
        2 => .vulkan,
        else => .log,
    };
}

fn layerShellOptionsFromRunOptions(options: *const KeyworkRunOptions) ?keywork.LayerShellOptions {
    if (options.layer_shell == 0) return null;
    return .{
        .namespace = cStringZ(options.layer_namespace, "keywork"),
        .layer = layerShellLayer(options.layer),
        .anchors = layerShellAnchors(options.layer_anchors),
        .exclusive_zone = options.layer_exclusive_zone,
        .margin = .{
            .top = options.layer_margin_top,
            .right = options.layer_margin_right,
            .bottom = options.layer_margin_bottom,
            .left = options.layer_margin_left,
        },
        .keyboard_interactivity = layerShellKeyboardInteractivity(options.layer_keyboard_interactivity),
    };
}

fn layerShellOptionsFromRunTextOptions(options: *const KeyworkRunTextOptions) ?keywork.LayerShellOptions {
    if (options.layer_shell == 0) return null;
    return .{
        .namespace = cStringZ(options.layer_namespace, "keywork"),
        .layer = layerShellLayer(options.layer),
        .anchors = layerShellAnchors(options.layer_anchors),
        .exclusive_zone = options.layer_exclusive_zone,
        .margin = .{
            .top = options.layer_margin_top,
            .right = options.layer_margin_right,
            .bottom = options.layer_margin_bottom,
            .left = options.layer_margin_left,
        },
        .keyboard_interactivity = layerShellKeyboardInteractivity(options.layer_keyboard_interactivity),
    };
}

fn layerShellLayer(value: c_int) keywork.LayerShellOptions.Layer {
    return switch (value) {
        0 => .background,
        1 => .bottom,
        3 => .overlay,
        else => .top,
    };
}

fn layerShellAnchors(value: u32) keywork.LayerShellOptions.AnchorSet {
    return .{
        .top = value & (1 << 0) != 0,
        .bottom = value & (1 << 1) != 0,
        .left = value & (1 << 2) != 0,
        .right = value & (1 << 3) != 0,
    };
}

fn layerShellKeyboardInteractivity(value: c_int) keywork.LayerShellOptions.KeyboardInteractivity {
    return switch (value) {
        1 => .exclusive,
        2 => .on_demand,
        else => .none,
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

test "c constructors build scroll, list, sized, and text input with on_change" {
    const allocator = std.testing.allocator;

    const TestApp = struct {
        var changes: usize = 0;
        var last_text: [32]u8 = undefined;
        var last_len: usize = 0;

        fn onChange(_: ?*anyopaque, text: [*:0]const u8, len: usize) callconv(.c) void {
            changes += 1;
            last_len = @min(len, last_text.len);
            @memcpy(last_text[0..last_len], text[0..last_len]);
        }

        fn buildItem(_: ?*anyopaque, build: *KeyworkBuild, index: usize) callconv(.c) ?*KeyworkWidget {
            var label: [32]u8 = undefined;
            const text = std.fmt.bufPrintZ(&label, "virtual row {d}", .{index}) catch return null;
            return keywork_text(build, text.ptr);
        }

        fn buildApp(_: ?*anyopaque, build: *KeyworkBuild, _: *const KeyworkContext) callconv(.c) ?*KeyworkWidget {
            const input = keywork_text_input_on_change(build, "input", "", "type here", onChange, null) orelse return null;
            const items = keywork_list(build, "rows", 1000, 20.0, buildItem, null) orelse return null;
            const sized = keywork_sized(build, items, -1, 60) orelse return null;
            const wrapped = keywork_scroll(build, "content", sized, 0) orelse return null;
            const children = [_]?*KeyworkWidget{ input, wrapped };
            return keywork_column(build, &children, children.len, 4);
        }
    };
    TestApp.changes = 0;

    var c_app: CApp = .{ .vtable = .{ .build = TestApp.buildApp }, .userdata = null };

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var log_backend: keywork.LogBackend = .{ .writer = &output.writer };
    var runtime = try keywork.Runtime.init(
        allocator,
        log_backend.backend(),
        .{ .max_width = 200, .max_height = 200 },
        c_app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.repaint();
    // The C item builder ran for visible rows only.
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "virtual row 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "virtual row 999") == null);

    // Typing reaches the C on_change callback through the retained tree.
    try runtime.keyInput(.{ .tab = .{} });
    try runtime.keyInput(.{ .text = "h" });
    try runtime.keyInput(.{ .text = "i" });
    try std.testing.expectEqual(@as(usize, 2), TestApp.changes);
    try std.testing.expectEqualStrings("hi", TestApp.last_text[0..TestApp.last_len]);
}
