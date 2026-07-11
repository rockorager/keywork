//! Runtime orchestration for Keywork applications.

const std = @import("std");
const keywork = @import("../ui.zig");

const log = std.log.scoped(.keywork);

const AppContext = keywork.AppContext;
const AppHost = keywork.AppHost;
const Constraints = keywork.Constraints;
const BuildScope = keywork.BuildScope;
const DisplayList = keywork.DisplayList;
const RasterCache = keywork.RasterCache;
const Element = keywork.Element;
const CursorShape = keywork.CursorShape;
const KeyInput = keywork.KeyInput;
const Point = keywork.Point;
const RenderBackend = keywork.RenderBackend;
const RenderNode = keywork.RenderNode;
const Size = keywork.Size;

const animation = @import("animation.zig");
const backend_behavior = @import("runtime/backend_behavior.zig");
const focus_scroll = @import("runtime/focus_scroll.zig");
const input_behavior = @import("runtime/input.zig");
const lifecycle_reconciliation = @import("runtime/lifecycle_reconciliation.zig");

pub const UiColorScheme = enum {
    no_preference,
    dark,
    light,

    pub fn name(self: UiColorScheme) []const u8 {
        return switch (self) {
            .no_preference => "no-preference",
            .dark => "dark",
            .light => "light",
        };
    }
};

/// Rebuild-request interface an app host holds instead of a concrete
/// runtime, so hosts work unchanged whether one runtime or a whole
/// window set sits behind it.
pub const Invalidator = struct {
    ptr: *anyopaque,
    invalidate_fn: *const fn (ptr: *anyopaque) anyerror!void,
    invalidate_state_fn: *const fn (ptr: *anyopaque) anyerror!void,

    pub fn invalidate(self: Invalidator) !void {
        try self.invalidate_fn(self.ptr);
    }

    pub fn invalidateState(self: Invalidator) !void {
        try self.invalidate_state_fn(self.ptr);
    }

    pub fn fromRuntime(runtime: *Runtime) Invalidator {
        return .{
            .ptr = runtime,
            .invalidate_fn = runtimeInvalidate,
            .invalidate_state_fn = runtimeInvalidateState,
        };
    }

    fn runtimeInvalidate(ptr: *anyopaque) anyerror!void {
        const runtime: *Runtime = @ptrCast(@alignCast(ptr));
        try runtime.invalidate();
    }

    fn runtimeInvalidateState(ptr: *anyopaque) anyerror!void {
        const runtime: *Runtime = @ptrCast(@alignCast(ptr));
        try runtime.invalidateState();
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    backend: RenderBackend,
    constraints: Constraints,
    app: AppHost,
    build_arena: std.heap.ArenaAllocator,
    color_scheme: UiColorScheme,
    focused_id: ?[]u8 = null,
    autofocus_suppressed: bool = false,
    hovered_id: ?[]u8 = null,
    pressed_id: ?[]u8 = null,
    pressed_button: ?keywork.PointerButton = null,
    /// Active scrollbar thumb drag. The pointer stays captured by the
    /// drag until release, so motion keeps scrolling even after leaving
    /// the thumb or the viewport.
    scrollbar_drag: ?ScrollbarDrag = null,
    element_root: ?Element = null,
    root: ?*RenderNode = null,
    display_list: DisplayList = .{},
    owned_raster_cache: RasterCache = .{},
    external_raster_cache: ?*RasterCache = null,
    app_context: State = .{},
    frame_background: ?keywork.Color = null,
    repaint_pending: bool = false,
    pending_interaction_ids: std.ArrayList([]u8) = .empty,
    rebuild_pending: bool = false,
    state_rebuild_pending: bool = false,
    frame_pending: bool = false,
    rendering: bool = false,
    defer_repaint_until_flush: bool = false,
    /// Size and scale of the last presented frame. A repaint whose rebuild
    /// passes produced no damage at an unchanged size and scale presents
    /// nothing, so app-wide state invalidations don't repaint clean windows.
    presented_size: ?keywork.Size = null,
    presented_scale: f32 = 0,
    repaint_scheduler: ?RepaintScheduler = null,
    repaint_scheduler_context: ?*anyopaque = null,
    /// Monotonic time source for animations; injectable so tests drive
    /// frames deterministically.
    clock: animation.Clock = .{},
    /// Whether any animation demanded another frame at the end of the
    /// last presented frame. While set, each presented frame re-requests
    /// a repaint so the backend's frame pacing sustains the loop; when it
    /// clears, the runtime returns to zero-cost idle.
    animations_active: bool = false,

    pub const RepaintScheduler = *const fn (ctx: *anyopaque) anyerror!void;

    pub const State = AppContext;

    pub fn init(
        allocator: std.mem.Allocator,
        backend: RenderBackend,
        constraints: Constraints,
        app: AppHost,
        color_scheme: UiColorScheme,
    ) !Runtime {
        return initWithOptionalRasterCache(allocator, backend, constraints, app, color_scheme, null);
    }

    pub fn initWithRasterCache(
        allocator: std.mem.Allocator,
        backend: RenderBackend,
        constraints: Constraints,
        app: AppHost,
        color_scheme: UiColorScheme,
        raster_cache: *RasterCache,
    ) !Runtime {
        return initWithOptionalRasterCache(allocator, backend, constraints, app, color_scheme, raster_cache);
    }

    fn initWithOptionalRasterCache(
        allocator: std.mem.Allocator,
        backend: RenderBackend,
        constraints: Constraints,
        app: AppHost,
        color_scheme: UiColorScheme,
        raster_cache: ?*RasterCache,
    ) !Runtime {
        var self: Runtime = .{
            .allocator = allocator,
            .backend = backend,
            .constraints = constraints,
            .app = app,
            .build_arena = .init(allocator),
            .color_scheme = color_scheme,
            .external_raster_cache = raster_cache,
        };
        errdefer self.deinit();
        try self.rebuild();
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.element_root) |*element_root| {
            keywork.destroyElementTree(self.allocator, element_root);
            self.element_root = null;
        }
        self.display_list.deinit(self.allocator);
        self.owned_raster_cache.deinit(self.allocator);
        if (self.focused_id) |id| self.allocator.free(id);
        for (self.pending_interaction_ids.items) |id| self.allocator.free(id);
        self.pending_interaction_ids.deinit(self.allocator);
        if (self.hovered_id) |id| self.allocator.free(id);
        if (self.pressed_id) |id| self.allocator.free(id);
        if (self.scrollbar_drag) |drag| self.allocator.free(drag.id);
        self.build_arena.deinit();
    }

    pub fn rasterCache(self: *Runtime) *RasterCache {
        return self.external_raster_cache orelse &self.owned_raster_cache;
    }

    fn currentState(self: *const Runtime) State {
        return lifecycle_reconciliation.currentState(self);
    }

    pub fn frameSize(self: *const Runtime) Size {
        return .{ .width = self.constraints.max_width, .height = self.constraints.max_height };
    }

    pub fn renderScale(self: *const Runtime) f32 {
        return backend_behavior.renderScale(self);
    }

    pub fn setFrameBackground(self: *Runtime, color: ?keywork.Color) void {
        backend_behavior.setFrameBackground(self, color);
    }

    pub fn frameBackground(self: *const Runtime) keywork.Color {
        return backend_behavior.frameBackground(self);
    }

    pub fn configure(self: *Runtime, size: Size) !void {
        try backend_behavior.configure(self, size);
    }

    pub fn repaint(self: *Runtime) !void {
        try self.presentFrame();
    }

    pub fn requestRepaint(self: *Runtime) !void {
        try backend_behavior.requestRepaint(self);
    }

    pub fn setDeferredRepaint(self: *Runtime, enabled: bool) void {
        backend_behavior.setDeferredRepaint(self, enabled);
    }

    pub fn flushPendingRepaint(self: *Runtime) !void {
        try backend_behavior.flushPendingRepaint(self);
    }

    pub fn setRepaintScheduler(self: *Runtime, context: *anyopaque, scheduler: RepaintScheduler) void {
        backend_behavior.setRepaintScheduler(self, context, scheduler);
    }

    pub fn invalidate(self: *Runtime) !void {
        try backend_behavior.invalidate(self);
    }

    pub fn invalidateState(self: *Runtime) !void {
        try backend_behavior.invalidateState(self);
    }

    /// Current animation time; the reference clock for starting timelines.
    pub fn animationNow(self: *const Runtime) u64 {
        return self.clock.now();
    }

    /// Popups declared by anchored elements in the current tree, with
    /// anchor rects from the last layout. Results borrow from the element
    /// tree and are invalidated by the next rebuild.
    pub fn collectPopupRequests(self: *const Runtime, allocator: std.mem.Allocator, out: *std.ArrayList(keywork.PopupRequest)) !void {
        if (self.element_root) |*element_root| {
            try keywork.collectPopupRequests(allocator, element_root, out);
        }
    }

    fn presentFrame(self: *Runtime) !void {
        try backend_behavior.presentFrame(self);
    }

    fn frameDone(self: *Runtime) !void {
        try backend_behavior.frameDone(self);
    }

    pub fn click(self: *Runtime, point: Point) !void {
        try input_behavior.click(self, point);
    }

    pub fn pointerButton(self: *Runtime, event: keywork.PointerButtonEvent) !void {
        try input_behavior.pointerButton(self, event);
    }

    pub const ScrollbarDrag = focus_scroll.ScrollbarDrag;

    fn pointerDown(self: *Runtime, point: Point) !void {
        try input_behavior.pointerDown(self, point);
    }

    fn beginScrollbarDrag(self: *Runtime, hit: keywork.ScrollbarThumbHit, point: Point) !void {
        try focus_scroll.beginScrollbarDrag(self, hit, point);
    }

    fn clearScrollbarDrag(self: *Runtime) void {
        focus_scroll.clearScrollbarDrag(self);
    }

    fn pointerUp(self: *Runtime, point: Point) !void {
        try input_behavior.pointerUp(self, point);
    }

    pub fn requestFocus(self: *Runtime, id: []const u8) !void {
        try focus_scroll.requestFocus(self, id);
    }

    pub fn clearFocus(self: *Runtime) !void {
        try focus_scroll.clearFocus(self);
    }

    fn setFocused(self: *Runtime, id: ?[]const u8) !bool {
        return focus_scroll.setFocused(self, id);
    }

    pub fn keyInput(self: *Runtime, input: KeyInput) !void {
        try input_behavior.keyInput(self, input);
    }

    fn activateShortcut(self: *Runtime, input: KeyInput) !bool {
        return input_behavior.activateShortcut(self, input);
    }

    fn focusedTarget(self: *Runtime) ?keywork.FocusTarget {
        return focus_scroll.focusedTarget(self);
    }

    fn focusedTargetIs(self: *Runtime, kind: keywork.FocusTarget.Kind) bool {
        return focus_scroll.focusedTargetIs(self, kind);
    }

    fn focusNext(self: *Runtime, reverse: bool) !void {
        try focus_scroll.focusNext(self, reverse);
    }

    fn revealFocused(self: *Runtime) !void {
        try focus_scroll.revealFocused(self);
    }

    fn activeModalScopeId(targets: []const keywork.FocusTarget) ?[]const u8 {
        return focus_scroll.activeModalScopeId(targets);
    }

    fn sameOptionalString(a: ?[]const u8, b: ?[]const u8) bool {
        return focus_scroll.sameOptionalString(a, b);
    }

    fn activateClick(self: *Runtime, hit: keywork.ClickHit, event: keywork.TapEvent) !bool {
        return input_behavior.activateClick(self, hit, event);
    }

    pub fn cursorShape(self: *Runtime, point: Point) CursorShape {
        return input_behavior.cursorShape(self, point);
    }

    pub fn pointerMove(self: *Runtime, point: ?Point) !void {
        try input_behavior.pointerMove(self, point);
    }

    fn setHoveredId(self: *Runtime, id: ?[]const u8) !bool {
        return input_behavior.setHoveredId(self, id);
    }

    fn setPressedId(self: *Runtime, id: ?[]const u8) !bool {
        return input_behavior.setPressedId(self, id);
    }

    fn queueInteractionRefresh(self: *Runtime, id: []const u8) !void {
        try input_behavior.queueInteractionRefresh(self, id);
    }

    fn flushInteractionRefresh(self: *Runtime) !void {
        try lifecycle_reconciliation.flushInteractionRefresh(self);
    }

    pub fn waylandPointerButton(ctx: *anyopaque, event: keywork.PointerButtonEvent) void {
        input_behavior.waylandPointerButton(Runtime, ctx, event);
    }

    pub fn waylandCursorShape(ctx: *anyopaque, point: Point) CursorShape {
        return input_behavior.waylandCursorShape(Runtime, ctx, point);
    }

    pub fn scrollBy(self: *Runtime, event: keywork.ScrollEvent) !void {
        try focus_scroll.scrollBy(self, event);
    }

    fn scrollElementById(self: *Runtime, id: []const u8, dx: f32, dy: f32) !void {
        try focus_scroll.scrollElementById(self, id, dx, dy);
    }

    pub fn waylandScroll(ctx: *anyopaque, event: keywork.ScrollEvent) void {
        focus_scroll.waylandScroll(Runtime, ctx, event);
    }

    pub fn waylandPointerMove(ctx: *anyopaque, point: ?Point) void {
        input_behavior.waylandPointerMove(Runtime, ctx, point);
    }

    pub fn waylandConfigure(ctx: *anyopaque, size: Size) void {
        backend_behavior.waylandConfigure(Runtime, ctx, size);
    }

    pub fn waylandFrameDone(ctx: *anyopaque) void {
        backend_behavior.waylandFrameDone(Runtime, ctx);
    }

    pub fn setColorScheme(self: *Runtime, color_scheme: UiColorScheme) !void {
        try backend_behavior.setColorScheme(self, color_scheme);
    }

    pub fn colorSchemeChanged(ctx: *anyopaque, color_scheme: UiColorScheme) void {
        backend_behavior.colorSchemeChanged(Runtime, ctx, color_scheme);
    }

    pub fn waylandKeyInput(ctx: *anyopaque, input: KeyInput) void {
        input_behavior.waylandKeyInput(Runtime, ctx, input);
    }

    fn rebuild(self: *Runtime) !void {
        try lifecycle_reconciliation.rebuild(self);
    }

    fn rebuildDirtyState(self: *Runtime) !void {
        try lifecycle_reconciliation.rebuildDirtyState(self);
    }

    fn buildScope(self: *Runtime, state: State) BuildScope {
        return lifecycle_reconciliation.buildScope(self, state);
    }

    fn rebuildRetainedTrees(self: *Runtime) !void {
        try lifecycle_reconciliation.rebuildRetainedTrees(self);
    }

    fn reconcileInteractionAfterRebuild(self: *Runtime) void {
        lifecycle_reconciliation.reconcileInteractionAfterRebuild(self);
    }

    fn reconcileFocusAfterRebuild(self: *Runtime) !bool {
        return lifecycle_reconciliation.reconcileFocusAfterRebuild(self);
    }

    fn autofocusTarget(targets: []const keywork.FocusTarget, modal_scope_id: ?[]const u8) ?keywork.FocusTarget {
        return lifecycle_reconciliation.autofocusTarget(targets, modal_scope_id);
    }
};

fn popLastGrapheme(bytes: *std.ArrayList(u8)) void {
    input_behavior.popLastGrapheme(bytes);
}

test "popLastGrapheme removes one extended grapheme cluster" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);

    try bytes.appendSlice(std.testing.allocator, "aé🇺🇸👩🏽‍🚀");
    popLastGrapheme(&bytes);
    try std.testing.expectEqualStrings("aé🇺🇸", bytes.items);
    popLastGrapheme(&bytes);
    try std.testing.expectEqualStrings("aé", bytes.items);
    popLastGrapheme(&bytes);
    try std.testing.expectEqualStrings("a", bytes.items);
    popLastGrapheme(&bytes);
    try std.testing.expectEqualStrings("", bytes.items);
}

test "invalidation raised during rebuild is not dropped" {
    const TestApp = struct {
        builds: usize = 0,
        runtime: ?*Runtime = null,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, _: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.builds += 1;
            // Re-invalidate exactly once from inside a rebuild pass.
            if (self.builds == 2) {
                if (self.runtime) |runtime| try runtime.invalidate();
            }
            return keywork.widgets.text("hello");
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    app.runtime = &runtime;

    try std.testing.expectEqual(@as(usize, 1), app.builds);
    try runtime.invalidate();
    try std.testing.expectEqual(@as(usize, 3), app.builds);
    try std.testing.expect(!runtime.rebuild_pending);
    try std.testing.expect(!runtime.state_rebuild_pending);
}

test "deferred invalidations coalesce until flush" {
    const TestApp = struct {
        builds: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.builds += 1;
            return keywork.widgets.text(try std.fmt.allocPrint(scope.allocator, "build {d}", .{self.builds}));
        }
    };

    const TestBackend = struct {
        presents: usize = 0,

        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(ptr: *anyopaque, _: RenderBackend.Frame) !bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.presents += 1;
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(std.testing.allocator, backend.backend(), .{ .max_width = 100, .max_height = 40 }, app.host(), .no_preference);
    defer runtime.deinit();
    try runtime.repaint();
    try std.testing.expectEqual(@as(usize, 1), backend.presents);
    runtime.setDeferredRepaint(true);
    try runtime.invalidate();
    try runtime.invalidateState();
    try std.testing.expectEqual(@as(usize, 1), backend.presents);
    try runtime.flushPendingRepaint();
    try std.testing.expectEqual(@as(usize, 2), backend.presents);
}

test "rebuild passes that never stabilize return an error" {
    const TestApp = struct {
        runtime: ?*Runtime = null,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, _: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.runtime) |runtime| try runtime.invalidate();
            return keywork.widgets.text("hello");
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    app.runtime = &runtime;

    try std.testing.expectError(error.RebuildDidNotStabilize, runtime.invalidate());
}

test "rebuilds that change nothing present nothing" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, _: *BuildScope, _: AppContext) !keywork.Widget {
            return keywork.widgets.text("hello");
        }
    };

    const TestBackend = struct {
        presents: usize = 0,

        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(ptr: *anyopaque, _: RenderBackend.Frame) !bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.presents += 1;
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(std.testing.allocator, backend.backend(), .{ .max_width = 100, .max_height = 40 }, app.host(), .no_preference);
    defer runtime.deinit();
    try runtime.repaint();
    try std.testing.expectEqual(@as(usize, 1), backend.presents);

    // A state invalidation that dirties no scope relayouts nothing.
    try runtime.invalidateState();
    try std.testing.expectEqual(@as(usize, 1), backend.presents);

    // A full rebuild still refreshes the retained tree, but identical
    // layout and paint output does not manufacture damage.
    try runtime.invalidate();
    try std.testing.expectEqual(@as(usize, 1), backend.presents);
}

fn renderedInputText(node: *const RenderNode) ?[]const u8 {
    if (node.kind == .text_input) return node.text;
    for (node.children) |child| {
        if (renderedInputText(child)) |text| return text;
    }
    return null;
}

test "tab traversal focuses widgets and enter activates focused clickable" {
    const TestApp = struct {
        clicks: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const input = keywork.widgets.textInput("input", "", "placeholder");
            const button = try keywork.widgets.button(scope.allocator, "button", "Button", .{ .ptr = self, .call_fn = increment });
            const children = [_]keywork.Widget{ input, button };
            return keywork.widgets.column(scope.allocator, &children, 4);
        }

        fn increment(ptr: *anyopaque, event: keywork.TapEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try std.testing.expectEqual(keywork.TapSource.keyboard, event.source);
            try std.testing.expectEqual(@as(?keywork.PointerButton, null), event.button);
            self.clicks += 1;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);
    try runtime.keyInput(.{ .text = "a" });
    try std.testing.expectEqualStrings("a", renderedInputText(runtime.root.?).?);

    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("button", runtime.focused_id.?);
    try runtime.keyInput(.enter);
    try std.testing.expectEqual(@as(usize, 1), app.clicks);
    try runtime.keyInput(.space);
    try std.testing.expectEqual(@as(usize, 2), app.clicks);

    try runtime.keyInput(.{ .tab = .{ .reverse = true } });
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);
    try runtime.keyInput(.space);
    try std.testing.expectEqualStrings("a ", renderedInputText(runtime.root.?).?);
}

test "accepted non-left buttons tap with event details, filtered buttons do nothing" {
    const TestApp = struct {
        clicks: usize = 0,
        last_button: ?keywork.PointerButton = null,
        last_source: ?keywork.TapSource = null,
        had_local: bool = false,
        accept_any: bool,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var widget = try keywork.widgets.clickable(
                scope.allocator,
                "target",
                keywork.widgets.text("Target"),
                .{ .ptr = self, .call_fn = record },
            );
            if (self.accept_any) widget.clickable.buttons = .any;
            return widget;
        }

        fn record(ptr: *anyopaque, event: keywork.TapEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.clicks += 1;
            self.last_button = event.button;
            self.last_source = event.source;
            self.had_local = event.local != null;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var backend: TestBackend = .{};
    const point: keywork.Point = .{ .x = 5, .y = 5 };

    var any_app: TestApp = .{ .accept_any = true };
    var any_runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        any_app.host(),
        .no_preference,
    );
    defer any_runtime.deinit();

    try any_runtime.pointerButton(.{ .button = .right, .state = .pressed, .position = point });
    try any_runtime.pointerButton(.{ .button = .right, .state = .released, .position = point });
    try std.testing.expectEqual(@as(usize, 1), any_app.clicks);
    try std.testing.expectEqual(@as(?keywork.PointerButton, .right), any_app.last_button);
    try std.testing.expectEqual(@as(?keywork.TapSource, .pointer), any_app.last_source);
    try std.testing.expect(any_app.had_local);

    var plain_app: TestApp = .{ .accept_any = false };
    var plain_runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        plain_app.host(),
        .no_preference,
    );
    defer plain_runtime.deinit();

    try plain_runtime.pointerButton(.{ .button = .right, .state = .pressed, .position = point });
    try plain_runtime.pointerButton(.{ .button = .right, .state = .released, .position = point });
    try std.testing.expectEqual(@as(usize, 0), plain_app.clicks);

    try plain_runtime.pointerButton(.{ .button = .left, .state = .pressed, .position = point });
    try plain_runtime.pointerButton(.{ .button = .left, .state = .released, .position = point });
    try std.testing.expectEqual(@as(usize, 1), plain_app.clicks);
    try std.testing.expectEqual(@as(?keywork.PointerButton, .left), plain_app.last_button);
}

test "in-flight press ignores other buttons until the initiating button releases" {
    const TestApp = struct {
        clicks: usize = 0,
        last_button: ?keywork.PointerButton = null,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var widget = try keywork.widgets.clickable(
                scope.allocator,
                "target",
                keywork.widgets.text("Target"),
                .{ .ptr = self, .call_fn = record },
            );
            widget.clickable.buttons = .any;
            widget.clickable.activation = .release;
            return widget;
        }

        fn record(ptr: *anyopaque, event: keywork.TapEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.clicks += 1;
            self.last_button = event.button;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    const point: keywork.Point = .{ .x = 5, .y = 5 };
    try runtime.pointerButton(.{ .button = .left, .state = .pressed, .position = point });
    try runtime.pointerButton(.{ .button = .right, .state = .pressed, .position = point });
    try runtime.pointerButton(.{ .button = .right, .state = .released, .position = point });
    try std.testing.expectEqual(@as(usize, 0), app.clicks);

    try runtime.pointerButton(.{ .button = .left, .state = .released, .position = point });
    try std.testing.expectEqual(@as(usize, 1), app.clicks);
    try std.testing.expectEqual(@as(?keywork.PointerButton, .left), app.last_button);
}

test "wheel scroll moves viewport content without rebuilding" {
    const TestApp = struct {
        builds: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.builds += 1;
            var rows: [20]keywork.Widget = undefined;
            for (&rows) |*row| row.* = keywork.widgets.text("row");
            const column = try keywork.widgets.column(scope.allocator, &rows, 0);
            return keywork.widgets.scroll(scope.allocator, "list", column);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), app.builds);
    // 20 rows at 16px in a 120px viewport: 200px of scroll range.
    try std.testing.expectEqual(@as(f32, 0), runtime.root.?.children[0].rect.y);

    try runtime.scrollBy(.{ .position = .{ .x = 5, .y = 5 }, .dx = 0, .dy = 30 });
    try std.testing.expectEqual(@as(f32, -30), runtime.root.?.children[0].rect.y);
    try std.testing.expectEqual(@as(usize, 1), app.builds);

    // Scrolling past the edges clamps.
    try runtime.scrollBy(.{ .position = .{ .x = 5, .y = 5 }, .dx = 0, .dy = 10_000 });
    try std.testing.expectEqual(@as(f32, -200), runtime.root.?.children[0].rect.y);
    try runtime.scrollBy(.{ .position = .{ .x = 5, .y = 5 }, .dx = 0, .dy = -10_000 });
    try std.testing.expectEqual(@as(f32, 0), runtime.root.?.children[0].rect.y);
    try std.testing.expectEqual(@as(usize, 1), app.builds);

    // Scrolling outside any viewport is a no-op.
    try runtime.scrollBy(.{ .position = .{ .x = 5, .y = 500 }, .dx = 0, .dy = 30 });
    try std.testing.expectEqual(@as(f32, 0), runtime.root.?.children[0].rect.y);
}

test "dragging the scrollbar thumb scrolls and captures the pointer" {
    const TestApp = struct {
        builds: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.builds += 1;
            var rows: [20]keywork.Widget = undefined;
            for (&rows) |*row| row.* = keywork.widgets.text("row");
            const column = try keywork.widgets.column(scope.allocator, &rows, 0);
            return keywork.widgets.scroll(scope.allocator, "list", column);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    // 20 rows at 16px in a 120px viewport: content 320, scroll range 200.
    // Thumb: track 114 (120 minus a 3px margin each end), length
    // max(12, 114*120/320) = 42.75, travel 71.25.
    const drag_scale: f32 = 200.0 / 71.25;
    // The viewport shrink-wraps its child's width; the thumb hugs its
    // right edge.
    const viewport = runtime.root.?.rect;
    const thumb_x = viewport.x + viewport.width - 6;

    // The thumb rests hidden; scroll activity reveals it without moving
    // the content, so it can be grabbed.
    try runtime.scrollBy(.{ .position = .{ .x = thumb_x, .y = 10 }, .dx = 0, .dy = 0 });

    // Press on the thumb; this starts a drag, not a click.
    try runtime.pointerButton(.{ .button = .left, .state = .pressed, .position = .{ .x = thumb_x, .y = 10 } });
    try std.testing.expect(runtime.scrollbar_drag != null);

    // Dragging down moves the content proportionally without rebuilding.
    try runtime.pointerMove(.{ .x = thumb_x, .y = 39 });
    try std.testing.expectApproxEqAbs(@as(f32, -29 * drag_scale), runtime.root.?.children[0].rect.y, 0.01);
    try std.testing.expectEqual(@as(usize, 1), app.builds);

    // The drag stays captured when the pointer leaves the viewport.
    try runtime.pointerMove(.{ .x = 500, .y = 1000 });
    try std.testing.expectEqual(@as(f32, -200), runtime.root.?.children[0].rect.y);
    try runtime.pointerMove(.{ .x = 500, .y = -1000 });
    try std.testing.expectEqual(@as(f32, 0), runtime.root.?.children[0].rect.y);

    // Release ends the drag; further motion no longer scrolls.
    try runtime.pointerButton(.{ .button = .left, .state = .released, .position = .{ .x = 500, .y = -1000 } });
    try std.testing.expect(runtime.scrollbar_drag == null);
    try runtime.pointerMove(.{ .x = thumb_x, .y = 60 });
    try std.testing.expectEqual(@as(f32, 0), runtime.root.?.children[0].rect.y);
    try std.testing.expectEqual(@as(usize, 1), app.builds);
}

test "non-left buttons do not start scrollbar drags" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            var rows: [20]keywork.Widget = undefined;
            for (&rows) |*row| row.* = keywork.widgets.text("row");
            const column = try keywork.widgets.column(scope.allocator, &rows, 0);
            return keywork.widgets.scroll(scope.allocator, "list", column);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    const viewport = runtime.root.?.rect;
    const thumb_x = viewport.x + viewport.width - 6;

    // Reveal the resting-hidden thumb so it can be grabbed at all.
    try runtime.scrollBy(.{ .position = .{ .x = thumb_x, .y = 10 }, .dx = 0, .dy = 0 });

    // A right press on the thumb neither starts a drag nor scrolls.
    try runtime.pointerButton(.{ .button = .right, .state = .pressed, .position = .{ .x = thumb_x, .y = 10 } });
    try std.testing.expect(runtime.scrollbar_drag == null);
    try runtime.pointerMove(.{ .x = thumb_x, .y = 39 });
    try std.testing.expectEqual(@as(f32, 0), runtime.root.?.children[0].rect.y);
    try runtime.pointerButton(.{ .button = .right, .state = .released, .position = .{ .x = thumb_x, .y = 39 } });

    // The left button still starts a drag afterwards, and a right release
    // mid-drag does not end the capture; only the initiating button does.
    try runtime.pointerButton(.{ .button = .left, .state = .pressed, .position = .{ .x = thumb_x, .y = 10 } });
    try std.testing.expect(runtime.scrollbar_drag != null);
    try runtime.pointerButton(.{ .button = .right, .state = .released, .position = .{ .x = thumb_x, .y = 10 } });
    try std.testing.expect(runtime.scrollbar_drag != null);
    try runtime.pointerButton(.{ .button = .left, .state = .released, .position = .{ .x = thumb_x, .y = 10 } });
    try std.testing.expect(runtime.scrollbar_drag == null);
}

/// Fake monotonic clock for driving animation frames deterministically.
const FakeClock = struct {
    now_ns: u64 = 0,

    fn clock(self: *FakeClock) @import("animation.zig").Clock {
        return .{ .ptr = self, .now_fn = now };
    }

    fn now(ptr: ?*anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(ptr.?));
        return self.now_ns;
    }
};

test "scrollbar reveals on scroll and fades out on the animation clock" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            var rows: [20]keywork.Widget = undefined;
            for (&rows) |*row| row.* = keywork.widgets.text("row");
            const column = try keywork.widgets.column(scope.allocator, &rows, 0);
            return keywork.widgets.scroll(scope.allocator, "list", column);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    const animation_module = @import("animation.zig");
    var fake_clock: FakeClock = .{};
    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    runtime.clock = fake_clock.clock();

    // The thumb rests hidden and the runtime idles with no frame demand.
    try runtime.repaint();
    try std.testing.expectEqual(@as(f32, 0), runtime.root.?.scrollbar_alpha);
    try std.testing.expect(!runtime.animations_active);
    try std.testing.expect(!runtime.repaint_pending);

    // Scroll activity shows the thumb at full alpha and starts the fade,
    // which registers continuous frame demand.
    try runtime.scrollBy(.{ .position = .{ .x = 5, .y = 5 }, .dx = 0, .dy = 30 });
    try std.testing.expectEqual(@as(f32, 1), runtime.root.?.scrollbar_alpha);
    try std.testing.expect(runtime.animations_active);
    try std.testing.expect(runtime.repaint_pending);

    // The thumb holds at full alpha, then eases out.
    fake_clock.now_ns = animation_module.scrollbar_fade_hold_ms * std.time.ns_per_ms / 2;
    try runtime.repaint();
    try std.testing.expectEqual(@as(f32, 1), runtime.root.?.scrollbar_alpha);

    fake_clock.now_ns = (animation_module.scrollbar_fade_hold_ms + animation_module.scrollbar_fade_duration_ms / 2) * std.time.ns_per_ms;
    try runtime.repaint();
    try std.testing.expect(runtime.root.?.scrollbar_alpha > 0 and runtime.root.?.scrollbar_alpha < 1);
    try std.testing.expect(runtime.animations_active);

    // Completion lands at exactly invisible and drops the frame demand.
    fake_clock.now_ns = animation_module.scrollbar_fade_total_ns;
    try runtime.repaint();
    try std.testing.expectApproxEqAbs(@as(f32, 0), runtime.root.?.scrollbar_alpha, 0.001);
    try std.testing.expect(!runtime.animations_active);

    // Renewed activity restarts the cycle from full alpha.
    try runtime.scrollBy(.{ .position = .{ .x = 5, .y = 5 }, .dx = 0, .dy = -10 });
    try std.testing.expectEqual(@as(f32, 1), runtime.root.?.scrollbar_alpha);
    try std.testing.expect(runtime.animations_active);
}

test "spinner sweeps on the animation clock and demands frames while mounted" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, _: *BuildScope, _: AppContext) !keywork.Widget {
            return keywork.widgets.spinner(.{ .period_ms = 1000 });
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var fake_clock: FakeClock = .{ .now_ns = 5000 * std.time.ns_per_ms };
    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 100, .max_height = 100 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    runtime.clock = fake_clock.clock();

    // The first tick captures the phase baseline at the current time, so
    // the sweep starts at zero regardless of the clock's absolute value.
    try runtime.repaint();
    try std.testing.expectEqual(@as(f32, 0), runtime.root.?.spinner_progress);
    try std.testing.expect(runtime.animations_active);
    try std.testing.expect(runtime.repaint_pending);

    fake_clock.now_ns += 250 * std.time.ns_per_ms;
    try runtime.repaint();
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), runtime.root.?.spinner_progress, 0.001);

    // The sweep wraps instead of terminating; demand never drops while
    // the spinner stays mounted.
    fake_clock.now_ns += 1000 * std.time.ns_per_ms;
    try runtime.repaint();
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), runtime.root.?.spinner_progress, 0.001);
    try std.testing.expect(runtime.animations_active);
}

test "non-left buttons do not move text-input focus" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const input = keywork.widgets.textInput("input", "", "placeholder");
            const label = keywork.widgets.text("label");
            const children = [_]keywork.Widget{ input, label };
            return try keywork.widgets.column(scope.allocator, &children, 4);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    const input_point: keywork.Point = .{ .x = 5, .y = 5 };
    const empty_point: keywork.Point = .{ .x = 150, .y = 100 };

    // A right click on the input does not focus it.
    try runtime.pointerButton(.{ .button = .right, .state = .pressed, .position = input_point });
    try runtime.pointerButton(.{ .button = .right, .state = .released, .position = input_point });
    try std.testing.expect(runtime.focused_id == null);

    // A left click focuses; a right click on empty space keeps that focus.
    try runtime.click(input_point);
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);
    try runtime.pointerButton(.{ .button = .right, .state = .pressed, .position = empty_point });
    try runtime.pointerButton(.{ .button = .right, .state = .released, .position = empty_point });
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);

    // A left click on empty space clears the focus.
    try runtime.click(empty_point);
    try std.testing.expect(runtime.focused_id == null);
}

test "right click on a text input bubbles to a button-accepting ancestor" {
    const TestApp = struct {
        clicks: usize = 0,
        last_button: ?keywork.PointerButton = null,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var widget = try keywork.widgets.clickable(
                scope.allocator,
                "wrapper",
                keywork.widgets.textInput("input", "", "placeholder"),
                .{ .ptr = self, .call_fn = record },
            );
            widget.clickable.buttons = .any;
            return widget;
        }

        fn record(ptr: *anyopaque, event: keywork.TapEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.clicks += 1;
            self.last_button = event.button;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    const input_point: keywork.Point = .{ .x = 5, .y = 5 };

    // A right click over the input reaches the wrapping clickable, which
    // takes the click (and focus) instead of the input.
    try runtime.pointerButton(.{ .button = .right, .state = .pressed, .position = input_point });
    try runtime.pointerButton(.{ .button = .right, .state = .released, .position = input_point });
    try std.testing.expectEqual(@as(usize, 1), app.clicks);
    try std.testing.expectEqual(@as(?keywork.PointerButton, .right), app.last_button);
    try std.testing.expectEqualStrings("wrapper", runtime.focused_id.?);

    // A left click still focuses the input instead of clicking the wrapper.
    try runtime.click(input_point);
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);
    try std.testing.expectEqual(@as(usize, 1), app.clicks);
}

test "releasing a non-left press outside the target fires tap_cancel" {
    const TestApp = struct {
        clicks: usize = 0,
        ups: usize = 0,
        cancels: usize = 0,
        cancel_button: ?keywork.PointerButton = null,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var widget = try keywork.widgets.clickable(
                scope.allocator,
                "target",
                keywork.widgets.text("Target"),
                .{ .ptr = self, .call_fn = recordClick },
            );
            widget.clickable.buttons = .any;
            widget.clickable.activation = .release;
            widget.clickable.on_tap_up = .{ .ptr = self, .call_fn = recordUp };
            widget.clickable.on_tap_cancel = .{ .ptr = self, .call_fn = recordCancel };
            return widget;
        }

        fn recordClick(ptr: *anyopaque, _: keywork.TapEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.clicks += 1;
        }

        fn recordUp(ptr: *anyopaque, _: keywork.TapEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.ups += 1;
        }

        fn recordCancel(ptr: *anyopaque, event: keywork.TapEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.cancels += 1;
            self.cancel_button = event.button;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.pointerButton(.{ .button = .right, .state = .pressed, .position = .{ .x = 5, .y = 5 } });
    try runtime.pointerButton(.{ .button = .right, .state = .released, .position = .{ .x = 150, .y = 100 } });
    try std.testing.expectEqual(@as(usize, 0), app.clicks);
    try std.testing.expectEqual(@as(usize, 0), app.ups);
    try std.testing.expectEqual(@as(usize, 1), app.cancels);
    try std.testing.expectEqual(@as(?keywork.PointerButton, .right), app.cancel_button);
}

test "keyboard focus scrolls its viewport to reveal the target" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            var rows: [12]keywork.Widget = undefined;
            var names: [12][]const u8 = undefined;
            for (&rows, 0..) |*row, index| {
                names[index] = try std.fmt.allocPrint(scope.allocator, "input-{d}", .{index});
                row.* = keywork.widgets.textInput(names[index], "", "");
            }
            const column = try keywork.widgets.column(scope.allocator, &rows, 0);
            return keywork.widgets.scroll(scope.allocator, "pane", column);
        }

        fn findFocusRect(node: *const keywork.RenderNode, id: []const u8) ?keywork.Rect {
            if (node.focus_id) |focus_id| {
                if (std.mem.eql(u8, focus_id, id)) return node.rect;
            }
            for (node.children) |child| {
                if (findFocusRect(child, id)) |rect| return rect;
            }
            return null;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 300, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    const viewport = runtime.root.?.rect;
    try std.testing.expect(runtime.root.?.scroll_content.height > viewport.height);

    // Tab through every input; each focused input must be inside the
    // viewport after the reveal scroll.
    for (0..12) |_| {
        try runtime.keyInput(.{ .tab = .{} });
        const focused = runtime.focused_id.?;
        const rect = TestApp.findFocusRect(runtime.root.?, focused).?;
        try std.testing.expect(rect.y >= viewport.y - 0.01);
        try std.testing.expect(rect.y + rect.height <= viewport.y + viewport.height + 0.01);
    }

    // Wrapping back to the first input scrolls the viewport up again.
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("input-0", runtime.focused_id.?);
    const rect = TestApp.findFocusRect(runtime.root.?, "input-0").?;
    try std.testing.expect(rect.y >= viewport.y - 0.01);
}

test "scrolling a virtualized list converges its window in one frame" {
    const TestApp = struct {
        builds: usize = 0,

        var dummy: u8 = 0;

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, _: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.builds += 1;
            return keywork.widgets.list("rows", 1000, 16, .{ .ptr = &dummy, .build_fn = buildItem });
        }

        fn buildItem(_: *const anyopaque, scope: *BuildScope, index: usize) !keywork.Widget {
            const label = try std.fmt.allocPrint(scope.allocator, "row {d}", .{index});
            return .{ .text = .{ .value = label } };
        }

        fn firstRowText(node: *const keywork.RenderNode) ?[]const u8 {
            if (node.kind == .text) return node.text;
            for (node.children) |child| {
                if (firstRowText(child)) |text| return text;
            }
            return null;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    try std.testing.expectEqualStrings("row 0", TestApp.firstRowText(runtime.root.?).?);

    // A deep scroll rebuilds the window through the frame loop's
    // convergence pass, with no app rebuild.
    try runtime.scrollBy(.{ .position = .{ .x = 5, .y = 5 }, .dx = 0, .dy = 8000 });
    try std.testing.expectEqualStrings("row 498", TestApp.firstRowText(runtime.root.?).?);
    try std.testing.expectEqual(@as(usize, 1), app.builds);

    try runtime.scrollBy(.{ .position = .{ .x = 5, .y = 5 }, .dx = 0, .dy = -100_000 });
    try std.testing.expectEqualStrings("row 0", TestApp.firstRowText(runtime.root.?).?);
    try std.testing.expectEqual(@as(usize, 1), app.builds);
}

test "wheel scroll reaches a selected list nested in a flexible column slot" {
    const TestApp = struct {
        var dummy: u8 = 0;

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        // Mirrors the launcher: column { header, expanded(box(padding(list))), footer }.
        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const allocator = scope.allocator;
            var list_widget = keywork.widgets.list("results", 64, 44, .{ .ptr = &dummy, .build_fn = buildItem });
            list_widget.list.selected = 0;
            const padded = try keywork.widgets.padding(allocator, .{ .left = 6, .right = 6, .top = 6, .bottom = 6 }, list_widget);
            const boxed: keywork.Widget = .{ .box = .{ .child = try keywork.Widget.alloc(allocator, padded) } };
            const children = [_]keywork.Widget{
                keywork.widgets.text("header"),
                try keywork.widgets.expandedFlex(allocator, boxed, 1),
                keywork.widgets.text("footer"),
            };
            return try keywork.widgets.column(allocator, &children, 0);
        }

        fn buildItem(_: *const anyopaque, scope: *BuildScope, index: usize) !keywork.Widget {
            const label = try std.fmt.allocPrint(scope.allocator, "row {d}", .{index});
            return .{ .text = .{ .value = label } };
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 640, .max_height = 470 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    const list_element = keywork.dirtyScrollElement(&runtime.element_root.?, "results").?;
    const state = keywork.listState(list_element);
    try std.testing.expectEqual(@as(f32, 0), state.offset);
    // The flexible slot bounds the viewport to the remaining window height.
    try std.testing.expect(state.viewport_height < 470);

    // A wheel event over the list scrolls it.
    try runtime.scrollBy(.{ .position = .{ .x = 320, .y = 200 }, .dx = 0, .dy = 100 });
    try std.testing.expectEqual(@as(f32, 100), state.offset);

    // The unchanged selection does not snap the free scroll back.
    try std.testing.expectEqual(@as(f32, 100), keywork.listState(list_element).offset);
}

test "present damage covers every display-list change during fast wheel scroll" {
    const TestApp = struct {
        var dummy: u8 = 0;

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        // Mirrors the launcher: column { header, expanded(box(padding(list))), footer },
        // rows are boxes filling their 44px slot.
        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const allocator = scope.allocator;
            const list_widget = keywork.widgets.list("results", 64, 44, .{ .ptr = &dummy, .build_fn = buildItem });
            const padded = try keywork.widgets.padding(allocator, .{ .left = 6, .right = 6, .top = 6, .bottom = 6 }, list_widget);
            const boxed: keywork.Widget = .{ .box = .{ .child = try keywork.Widget.alloc(allocator, padded) } };
            const children = [_]keywork.Widget{
                keywork.widgets.text("header"),
                try keywork.widgets.expandedFlex(allocator, boxed, 1),
                keywork.widgets.text("footer"),
            };
            return try keywork.widgets.column(allocator, &children, 0);
        }

        fn buildItem(_: *const anyopaque, scope: *BuildScope, index: usize) !keywork.Widget {
            const label = try std.fmt.allocPrint(scope.allocator, "row {d}", .{index});
            const text: keywork.Widget = .{ .text = .{ .value = label } };
            return .{ .box = .{ .child = try keywork.Widget.alloc(scope.allocator, text), .min_height = 44 } };
        }
    };

    // Snapshot of one paint command with its active clip, so consecutive
    // presents can be diffed: a command present in only one of two
    // consecutive frames changed pixels, and those pixels must fall inside
    // that present's damage rect. This is the invariant the SHM backend's
    // partial repaint relies on.
    const Entry = struct {
        clip: ?keywork.Rect,
        rect: keywork.Rect,
        color: keywork.Color,
        font_size: f32,
        cache_key: u64,
        kind: enum { fill, text, image },
        text: []u8,

        fn eql(self: @This(), other: @This()) bool {
            return self.kind == other.kind and
                std.meta.eql(self.clip, other.clip) and
                std.meta.eql(self.rect, other.rect) and
                std.meta.eql(self.color, other.color) and
                self.font_size == other.font_size and
                self.cache_key == other.cache_key and
                std.mem.eql(u8, self.text, other.text);
        }
    };

    const TestBackend = struct {
        allocator: std.mem.Allocator,
        prev: std.ArrayList(Entry) = .empty,
        presents: usize = 0,
        violations: usize = 0,

        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn deinit(self: *@This()) void {
            freeEntries(self.allocator, &self.prev);
        }

        fn freeEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(Entry)) void {
            for (entries.items) |entry| allocator.free(entry.text);
            entries.deinit(allocator);
        }

        fn snapshot(allocator: std.mem.Allocator, commands: []const keywork.PaintCommand) !std.ArrayList(Entry) {
            var entries: std.ArrayList(Entry) = .empty;
            errdefer freeEntries(allocator, &entries);
            var clip: ?keywork.Rect = null;
            for (commands) |command| {
                const entry: Entry = switch (command) {
                    .set_clip => |value| {
                        clip = value;
                        continue;
                    },
                    .fill_rect => |fill| .{
                        .clip = clip,
                        .rect = fill.rect,
                        .color = fill.color,
                        .font_size = 0,
                        .cache_key = 0,
                        .kind = .fill,
                        .text = &.{},
                    },
                    .text => |run| blk: {
                        const measurer: keywork.TextMeasurer = .fixed;
                        const size = try measurer.measureText(run.value, run.style);
                        break :blk .{
                            .clip = clip,
                            .rect = .{ .x = run.origin.x, .y = run.origin.y, .width = size.width, .height = size.height },
                            .color = run.style.color,
                            .font_size = run.style.font_size,
                            .cache_key = 0,
                            .kind = .text,
                            .text = try allocator.dupe(u8, run.value),
                        };
                    },
                    .alpha_image => |image| .{
                        .clip = clip,
                        .rect = image.rect,
                        .color = image.color,
                        .font_size = 0,
                        .cache_key = image.cache_key,
                        .kind = .image,
                        .text = &.{},
                    },
                    .color_image => |image| .{
                        .clip = clip,
                        .rect = image.rect,
                        .color = .{ .a = 0, .r = 0, .g = 0, .b = 0 },
                        .font_size = 0,
                        .cache_key = image.cache_key,
                        .kind = .image,
                        .text = &.{},
                    },
                };
                errdefer allocator.free(entry.text);
                try entries.append(allocator, entry);
            }
            return entries;
        }

        fn checkCovered(self: *@This(), entry: Entry, damage: keywork.Rect, side: []const u8) void {
            const effective = if (entry.clip) |clip| entry.rect.intersect(clip) else entry.rect;
            if (effective.isEmpty()) return;
            const epsilon = 0.01;
            const covered = damage.x <= effective.x + epsilon and
                damage.y <= effective.y + epsilon and
                damage.x + damage.width >= effective.x + effective.width - epsilon and
                damage.y + damage.height >= effective.y + effective.height - epsilon;
            if (covered) return;
            self.violations += 1;
            std.debug.print(
                "present {d}: {s} {t} \"{s}\" at {any} (clip {any}) outside damage {any}\n",
                .{ self.presents, side, entry.kind, entry.text, entry.rect, entry.clip, damage },
            );
        }

        fn present(ptr: *anyopaque, frame: RenderBackend.Frame) !bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.presents += 1;
            var current = try snapshot(self.allocator, frame.display_list);
            errdefer freeEntries(self.allocator, &current);
            try std.testing.expectEqual(@as(usize, 1), frame.damage.len);
            const damage = frame.damage[0];

            if (self.presents > 1) {
                const matched = try self.allocator.alloc(bool, self.prev.items.len);
                defer self.allocator.free(matched);
                @memset(matched, false);
                for (current.items) |entry| {
                    const found = for (self.prev.items, 0..) |old, index| {
                        if (!matched[index] and entry.eql(old)) break index;
                    } else null;
                    if (found) |index| {
                        matched[index] = true;
                    } else {
                        self.checkCovered(entry, damage, "new");
                    }
                }
                for (self.prev.items, 0..) |old, index| {
                    if (!matched[index]) self.checkCovered(old, damage, "vacated");
                }
            }

            freeEntries(self.allocator, &self.prev);
            self.prev = current;
            return true;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{ .allocator = std.testing.allocator };
    defer backend.deinit();
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 640, .max_height = 470 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    try runtime.frameDone();

    // Fast wheel input: within each burst the first event may present
    // immediately, the rest coalesce behind the pending frame callback and
    // render as one summed jump on frame done. Fractional deltas mirror
    // touchpad scrolling.
    const bursts = [_][]const f32{
        &.{100}, // plain wheel step
        &.{ 120, 120, 120 }, // fast: several events, one frame
        &.{900}, // jump farther than the built window
        &.{ 33.5, 41.25, 27.75, 38.5 }, // fractional touchpad deltas
        &.{ -240, -240, -240, -240 }, // fast back up
        &.{-100_000}, // clamped overshoot back to the top
    };
    for (bursts) |burst| {
        for (burst) |dy| {
            try runtime.scrollBy(.{ .position = .{ .x = 320, .y = 200 }, .dx = 0, .dy = dy });
        }
        try runtime.frameDone();
        try runtime.frameDone();
    }
    // Drain the scrollbar fade so animation-driven presents are checked too.
    var ticks: usize = 0;
    while (ticks < 120) : (ticks += 1) {
        try runtime.frameDone();
    }
    try std.testing.expect(backend.presents > bursts.len);
    try std.testing.expectEqual(@as(usize, 0), backend.violations);
}

test "typing edits element-owned input state without rebuilding" {
    const TestApp = struct {
        builds: usize = 0,
        last_change: [32]u8 = undefined,
        last_change_len: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.builds += 1;
            var first = keywork.widgets.textInput("first", "", "first");
            first.text_input.on_change = .{ .ptr = self, .call_fn = onChange };
            const second = keywork.widgets.textInput("second", "", "second");
            const children = [_]keywork.Widget{ first, second };
            return keywork.widgets.column(scope.allocator, &children, 4);
        }

        fn onChange(ptr: *anyopaque, text: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.last_change_len = @min(text.len, self.last_change.len);
            @memcpy(self.last_change[0..self.last_change_len], text[0..self.last_change_len]);
        }

        fn lastChange(self: *const @This()) []const u8 {
            return self.last_change[0..self.last_change_len];
        }

        fn collectInputTexts(node: *const keywork.RenderNode, out: [][]const u8, count: *usize) void {
            if (node.kind == .text_input) {
                out[count.*] = node.text orelse "";
                count.* += 1;
            }
            for (node.children) |child| collectInputTexts(child, out, count);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("first", runtime.focused_id.?);
    const builds_after_focus = app.builds;

    // Typing edits the element buffer and fires on_change with no rebuild.
    try runtime.keyInput(.{ .text = "h" });
    try runtime.keyInput(.{ .text = "i" });
    try std.testing.expectEqual(builds_after_focus, app.builds);
    try std.testing.expectEqualStrings("hi", app.lastChange());

    // The second input keeps independent state.
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("second", runtime.focused_id.?);
    try runtime.keyInput(.{ .text = "y" });
    try runtime.keyInput(.{ .text = "o" });

    var texts: [4][]const u8 = undefined;
    var count: usize = 0;
    TestApp.collectInputTexts(runtime.root.?, &texts, &count);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("hi", texts[0]);
    try std.testing.expectEqualStrings("yo", texts[1]);
    // on_change belongs to the first input; the second never fired it.
    try std.testing.expectEqualStrings("hi", app.lastChange());
}

test "pointer hover restyles buttons without a full rebuild" {
    const TestApp = struct {
        builds: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.builds += 1;
            const theme: keywork.Theme = .{
                .color_scheme = .light,
                .button_theme = .{
                    .background = keywork.colors.white,
                    .foreground = keywork.colors.ink,
                    .hover_background = keywork.colors.black,
                },
            };
            const first = try keywork.widgets.button(scope.allocator, "first", "First", .{ .ptr = self, .call_fn = noop });
            const second = try keywork.widgets.button(scope.allocator, "second", "Second", .{ .ptr = self, .call_fn = noop });
            const children = [_]keywork.Widget{ first, second };
            const column = try keywork.widgets.column(scope.allocator, &children, 4);
            return keywork.widgets.theme(scope.allocator, theme, column);
        }

        fn noop(_: *anyopaque, _: keywork.TapEvent) !void {}

        fn collectBoxBackgrounds(node: *const keywork.RenderNode, out: []keywork.Color, count: *usize) void {
            if (node.kind == .box) {
                out[count.*] = node.background;
                count.* += 1;
            }
            for (node.children) |child| collectBoxBackgrounds(child, out, count);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), app.builds);

    var backgrounds: [8]keywork.Color = undefined;
    var count: usize = 0;
    TestApp.collectBoxBackgrounds(runtime.root.?, &backgrounds, &count);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(keywork.colors.white, backgrounds[0]);
    try std.testing.expectEqual(keywork.colors.white, backgrounds[1]);

    // Hovering the first button restyles only it, with no root rebuild.
    try runtime.pointerMove(.{ .x = 5, .y = 5 });
    try std.testing.expectEqual(@as(usize, 1), app.builds);
    count = 0;
    TestApp.collectBoxBackgrounds(runtime.root.?, &backgrounds, &count);
    try std.testing.expectEqual(keywork.colors.black, backgrounds[0]);
    try std.testing.expectEqual(keywork.colors.white, backgrounds[1]);

    // Leaving the surface clears the hover styling, still without rebuilds.
    try runtime.pointerMove(null);
    try std.testing.expectEqual(@as(usize, 1), app.builds);
    count = 0;
    TestApp.collectBoxBackgrounds(runtime.root.?, &backgrounds, &count);
    try std.testing.expectEqual(keywork.colors.white, backgrounds[0]);
    try std.testing.expectEqual(keywork.colors.white, backgrounds[1]);
}

test "pointer motion fires clickable hover callbacks on enter and leave" {
    const TestApp = struct {
        enters: usize = 0,
        leaves: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const label: keywork.Widget = .{ .text = .{ .value = "row" } };
            const child = try keywork.Widget.alloc(scope.allocator, label);
            return .{ .clickable = .{
                .id = "row",
                .child = child,
                .on_click = .{ .ptr = self, .call_fn = noopTap },
                .on_hover_change = .{ .ptr = self, .call_fn = hoverChanged },
            } };
        }

        fn noopTap(_: *anyopaque, _: keywork.TapEvent) !void {}

        fn hoverChanged(ptr: *anyopaque, hovered: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (hovered) self.enters += 1 else self.leaves += 1;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.pointerMove(.{ .x = 5, .y = 5 });
    try std.testing.expectEqual(@as(usize, 1), app.enters);
    try std.testing.expectEqual(@as(usize, 0), app.leaves);

    // Motion within the same target must not re-fire.
    try runtime.pointerMove(.{ .x = 6, .y = 5 });
    try std.testing.expectEqual(@as(usize, 1), app.enters);

    try runtime.pointerMove(null);
    try std.testing.expectEqual(@as(usize, 1), app.enters);
    try std.testing.expectEqual(@as(usize, 1), app.leaves);
}

test "intent button callbacks survive dirty-state restyles" {
    const TestApp = struct {
        first_actions: usize = 0,
        second_actions: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const theme: keywork.Theme = .{
                .color_scheme = .light,
                .button_theme = .{
                    .background = keywork.colors.white,
                    .foreground = keywork.colors.ink,
                    .hover_background = keywork.colors.black,
                    .padding_x = 0,
                    .padding_y = 0,
                },
            };
            const first = try keywork.widgets.actionButton(scope.allocator, "first", "First", "one");
            const second = try keywork.widgets.actionButton(scope.allocator, "second", "Second", "two");
            const children = [_]keywork.Widget{ first, second };
            const column = try keywork.widgets.column(scope.allocator, &children, 4);
            const action_bindings = [_]keywork.Widget.ActionBinding{
                .{ .id = "one", .callback = .{ .ptr = self, .call_fn = incrementFirst } },
                .{ .id = "two", .callback = .{ .ptr = self, .call_fn = incrementSecond } },
            };
            const actions = try keywork.widgets.actions(scope.allocator, &action_bindings, column);
            return keywork.widgets.theme(scope.allocator, theme, actions);
        }

        fn incrementFirst(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.first_actions += 1;
        }

        fn incrementSecond(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.second_actions += 1;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    // Hovering restyles the first button through the dirty-state arena;
    // retained subtrees are cloned and must own their adapted action
    // callbacks rather than borrow arena memory that the reset frees.
    try runtime.pointerMove(.{ .x = 5, .y = 5 });
    try runtime.pointerMove(null);

    try runtime.click(.{ .x = 5, .y = 5 });
    try runtime.click(.{ .x = 5, .y = 25 });
    try std.testing.expectEqual(@as(usize, 1), app.first_actions);
    try std.testing.expectEqual(@as(usize, 1), app.second_actions);
}

test "shortcut invokes ambient action outside text input focus" {
    const TestApp = struct {
        actions: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const input = keywork.widgets.textInput("input", "", "placeholder");
            const label = keywork.widgets.text("Shortcut target");
            const children = [_]keywork.Widget{ input, label };
            const column = try keywork.widgets.column(scope.allocator, &children, 4);
            const shortcut_bindings = [_]keywork.Widget.ShortcutBinding{.{ .key = .space, .intent = .action("activate") }};
            const action_bindings = [_]keywork.Widget.ActionBinding{.{ .id = "activate", .callback = .{ .ptr = self, .call_fn = activate } }};
            const shortcuts = try keywork.widgets.shortcuts(scope.allocator, &shortcut_bindings, column);
            return keywork.widgets.actions(scope.allocator, &action_bindings, shortcuts);
        }

        fn activate(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.actions += 1;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.keyInput(.space);
    try std.testing.expectEqual(@as(usize, 1), app.actions);

    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);
    try runtime.keyInput(.space);
    try std.testing.expectEqual(@as(usize, 1), app.actions);
    try std.testing.expectEqualStrings(" ", renderedInputText(runtime.root.?).?);
}

test "bound tab fires its shortcut instead of traversal; shift-tab still traverses" {
    const TestApp = struct {
        actions: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var input = keywork.widgets.textInput("input", "", "placeholder");
            input.text_input.autofocus = true;
            const button = try keywork.widgets.button(scope.allocator, "button", "Button", .{ .ptr = self, .call_fn = ignoreTap });
            const children = [_]keywork.Widget{ input, button };
            const column = try keywork.widgets.column(scope.allocator, &children, 4);
            const shortcut_bindings = [_]keywork.Widget.ShortcutBinding{
                .{ .key = .tab, .intent = .action("activate") },
            };
            const action_bindings = [_]keywork.Widget.ActionBinding{.{ .id = "activate", .callback = .{ .ptr = self, .call_fn = activate } }};
            const shortcuts = try keywork.widgets.shortcuts(scope.allocator, &shortcut_bindings, column);
            return keywork.widgets.actions(scope.allocator, &action_bindings, shortcuts);
        }

        fn activate(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.actions += 1;
        }

        fn ignoreTap(_: *anyopaque, _: keywork.TapEvent) !void {}
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try std.testing.expectEqualStrings("input", runtime.focused_id.?);

    // Bound plain tab fires the shortcut and leaves focus alone, even
    // while the text input is focused.
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqual(@as(usize, 1), app.actions);
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);

    // Shift-tab never matches a tab shortcut; it keeps reverse traversal.
    try runtime.keyInput(.{ .tab = .{ .reverse = true } });
    try std.testing.expectEqual(@as(usize, 1), app.actions);
    try std.testing.expectEqualStrings("button", runtime.focused_id.?);
}

test "non-editing shortcuts fire while a text input is focused" {
    const TestApp = struct {
        actions: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var input = keywork.widgets.textInput("input", "", "placeholder");
            input.text_input.autofocus = true;
            const shortcut_bindings = [_]keywork.Widget.ShortcutBinding{
                .{ .key = .enter, .intent = .action("activate") },
                .{ .key = .escape, .intent = .action("activate") },
                .{ .key = .down, .intent = .action("activate") },
                .{ .key = .up, .intent = .action("activate") },
            };
            const action_bindings = [_]keywork.Widget.ActionBinding{.{ .id = "activate", .callback = .{ .ptr = self, .call_fn = activate } }};
            const shortcuts = try keywork.widgets.shortcuts(scope.allocator, &shortcut_bindings, input);
            return keywork.widgets.actions(scope.allocator, &action_bindings, shortcuts);
        }

        fn activate(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.actions += 1;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 200, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    // The autofocus text input owns focus from the initial build.
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);

    try runtime.keyInput(.enter);
    try runtime.keyInput(.escape);
    try runtime.keyInput(.down);
    try runtime.keyInput(.up);
    try std.testing.expectEqual(@as(usize, 4), app.actions);

    // Editing keys still reach the input instead of shortcuts.
    try runtime.keyInput(.{ .text = "hi" });
    try runtime.keyInput(.space);
    try runtime.keyInput(.backspace);
    try std.testing.expectEqual(@as(usize, 4), app.actions);
    try std.testing.expectEqualStrings("hi", renderedInputText(runtime.root.?).?);
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);
}

test "focus widget participates in traversal and shortcut context" {
    const TestApp = struct {
        actions: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const label = keywork.widgets.text("Focusable shortcut target");
            const focused_label = try keywork.widgets.focus(scope.allocator, .named("label-focus"), label);
            const shortcut_bindings = [_]keywork.Widget.ShortcutBinding{.{ .key = .space, .intent = .action("activate") }};
            const action_bindings = [_]keywork.Widget.ActionBinding{.{ .id = "activate", .callback = .{ .ptr = self, .call_fn = activate } }};
            const shortcuts = try keywork.widgets.shortcuts(scope.allocator, &shortcut_bindings, focused_label);
            return keywork.widgets.actions(scope.allocator, &action_bindings, shortcuts);
        }

        fn activate(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.actions += 1;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 80 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("label-focus", runtime.focused_id.?);
    try runtime.keyInput(.space);
    try std.testing.expectEqual(@as(usize, 1), app.actions);
}

test "autofocus focus node is selected during initial build" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            return keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("initial"),
                keywork.widgets.text("Initial focus"),
                .{ .autofocus = true },
            );
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 80 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try std.testing.expectEqualStrings("initial", runtime.focused_id.?);
    try std.testing.expect(runtime.root.?.focused);

    try runtime.clearFocus();
    try std.testing.expectEqual(@as(?[]u8, null), runtime.focused_id);
    try std.testing.expect(!runtime.root.?.focused);
}

test "autofocus replaces focused node removed during rebuild" {
    const TestApp = struct {
        show_old_focus: bool = true,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const first = if (self.show_old_focus)
                try keywork.widgets.focus(scope.allocator, .named("old"), keywork.widgets.text("Old"))
            else
                keywork.widgets.text("Removed");
            const replacement = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("replacement"),
                keywork.widgets.text("Replacement"),
                .{ .autofocus = true },
            );
            const children = [_]keywork.Widget{ first, replacement };
            return keywork.widgets.column(scope.allocator, &children, 4);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    _ = try runtime.setFocused("old");
    try runtime.rebuild();
    try std.testing.expectEqualStrings("old", runtime.focused_id.?);

    app.show_old_focus = false;
    try runtime.rebuild();
    try std.testing.expectEqualStrings("replacement", runtime.focused_id.?);
    try std.testing.expect(runtime.root.?.children[1].focused);
}

test "runtime requestFocus and clearFocus notify focus widgets" {
    const TestApp = struct {
        a_focused: usize = 0,
        a_blurred: usize = 0,
        b_focused: usize = 0,
        b_blurred: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const a = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("a"),
                keywork.widgets.text("A"),
                .{ .on_focus_change = .{ .ptr = self, .call_fn = focusA } },
            );
            const b = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("b"),
                keywork.widgets.text("B"),
                .{ .on_focus_change = .{ .ptr = self, .call_fn = focusB } },
            );
            const children = [_]keywork.Widget{ a, b };
            return keywork.widgets.column(scope.allocator, &children, 4);
        }

        fn focusA(ptr: *anyopaque, focused: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (focused) {
                self.a_focused += 1;
            } else {
                self.a_blurred += 1;
            }
        }

        fn focusB(ptr: *anyopaque, focused: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (focused) {
                self.b_focused += 1;
            } else {
                self.b_blurred += 1;
            }
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try std.testing.expectEqual(@as(?[]u8, null), runtime.focused_id);
    try runtime.requestFocus("a");
    try std.testing.expectEqualStrings("a", runtime.focused_id.?);
    try std.testing.expect(runtime.root.?.children[0].focused);
    try std.testing.expectEqual(@as(usize, 1), app.a_focused);
    try std.testing.expectEqual(@as(usize, 0), app.a_blurred);

    try runtime.requestFocus("b");
    try std.testing.expectEqualStrings("b", runtime.focused_id.?);
    try std.testing.expect(runtime.root.?.children[1].focused);
    try std.testing.expectEqual(@as(usize, 1), app.a_blurred);
    try std.testing.expectEqual(@as(usize, 1), app.b_focused);

    try runtime.clearFocus();
    try std.testing.expectEqual(@as(?[]u8, null), runtime.focused_id);
    try std.testing.expectEqual(@as(usize, 1), app.b_blurred);
    try std.testing.expectError(error.FocusTargetNotFound, runtime.requestFocus("missing"));
}

test "focus traversal respects request and traversal policy" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const a = try keywork.widgets.focus(scope.allocator, .named("a"), keywork.widgets.text("A"));
            const skipped = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("skipped"),
                keywork.widgets.text("Skipped"),
                .{ .skip_traversal = true },
            );
            const blocked = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("blocked"),
                keywork.widgets.text("Blocked"),
                .{ .autofocus = true, .can_request_focus = false },
            );
            const c = try keywork.widgets.focus(scope.allocator, .named("c"), keywork.widgets.text("C"));
            const children = [_]keywork.Widget{ a, skipped, blocked, c };
            return keywork.widgets.column(scope.allocator, &children, 4);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 160 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try std.testing.expectEqual(@as(?[]u8, null), runtime.focused_id);
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("a", runtime.focused_id.?);
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("c", runtime.focused_id.?);

    try runtime.requestFocus("skipped");
    try std.testing.expectEqualStrings("skipped", runtime.focused_id.?);
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("c", runtime.focused_id.?);
    try std.testing.expectError(error.FocusTargetNotFocusable, runtime.requestFocus("blocked"));
}

test "focused node becoming non-requestable falls back to autofocus" {
    const TestApp = struct {
        allow_a_focus: bool = true,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const a = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("a"),
                keywork.widgets.text("A"),
                .{ .can_request_focus = self.allow_a_focus },
            );
            const replacement = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("replacement"),
                keywork.widgets.text("Replacement"),
                .{ .autofocus = true },
            );
            const children = [_]keywork.Widget{ a, replacement };
            return keywork.widgets.column(scope.allocator, &children, 4);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 120 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.requestFocus("a");
    try std.testing.expectEqualStrings("a", runtime.focused_id.?);

    app.allow_a_focus = false;
    try runtime.rebuild();
    try std.testing.expectEqualStrings("replacement", runtime.focused_id.?);
    try std.testing.expect(runtime.root.?.children[1].focused);
}

test "focus scope contains tab traversal once focus is inside it" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const a1 = try keywork.widgets.focus(scope.allocator, .named("a1"), keywork.widgets.text("A1"));
            const a2 = try keywork.widgets.focus(scope.allocator, .named("a2"), keywork.widgets.text("A2"));
            const a_children = [_]keywork.Widget{ a1, a2 };
            const a_column = try keywork.widgets.column(scope.allocator, &a_children, 4);
            const scope_a = try keywork.widgets.focusScope(scope.allocator, "scope-a", a_column);

            const b1 = try keywork.widgets.focus(scope.allocator, .named("b1"), keywork.widgets.text("B1"));
            const b2 = try keywork.widgets.focus(scope.allocator, .named("b2"), keywork.widgets.text("B2"));
            const b_children = [_]keywork.Widget{ b1, b2 };
            const b_column = try keywork.widgets.column(scope.allocator, &b_children, 4);
            const scope_b = try keywork.widgets.focusScope(scope.allocator, "scope-b", b_column);

            const children = [_]keywork.Widget{ scope_a, scope_b };
            return keywork.widgets.column(scope.allocator, &children, 8);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 160 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("a1", runtime.focused_id.?);
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("a2", runtime.focused_id.?);
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("a1", runtime.focused_id.?);
    try runtime.keyInput(.{ .tab = .{ .reverse = true } });
    try std.testing.expectEqualStrings("a2", runtime.focused_id.?);
}

test "modal focus scope traps autofocus traversal and focus requests" {
    const TestApp = struct {
        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(_: *anyopaque, scope: *BuildScope, _: AppContext) !keywork.Widget {
            const background = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("background"),
                keywork.widgets.text("Background"),
                .{ .autofocus = true },
            );

            const modal_a = try keywork.widgets.focusWithOptions(
                scope.allocator,
                .named("modal-a"),
                keywork.widgets.text("Modal A"),
                .{ .autofocus = true },
            );
            const modal_b = try keywork.widgets.focus(scope.allocator, .named("modal-b"), keywork.widgets.text("Modal B"));
            const modal_children = [_]keywork.Widget{ modal_a, modal_b };
            const modal_column = try keywork.widgets.column(scope.allocator, &modal_children, 4);
            const modal = try keywork.widgets.focusScopeWithOptions(scope.allocator, "modal", modal_column, .{ .modal = true });

            const after_modal = try keywork.widgets.focus(scope.allocator, .named("after-modal"), keywork.widgets.text("After modal"));
            const children = [_]keywork.Widget{ background, modal, after_modal };
            return keywork.widgets.column(scope.allocator, &children, 8);
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8, style: keywork.ResolvedTextStyle) !Size {
            const measurer: keywork.TextMeasurer = .fixed;
            return measurer.measureText(value, style);
        }

        fn scale(_: *anyopaque) f32 {
            return 1;
        }
    };

    var app: TestApp = .{};
    var backend: TestBackend = .{};
    var runtime = try Runtime.init(
        std.testing.allocator,
        backend.backend(),
        .{ .max_width = 240, .max_height = 180 },
        app.host(),
        .no_preference,
    );
    defer runtime.deinit();

    try std.testing.expectEqualStrings("modal-a", runtime.focused_id.?);
    try std.testing.expectError(error.FocusTargetOutsideModal, runtime.requestFocus("background"));
    try std.testing.expectError(error.FocusTargetOutsideModal, runtime.requestFocus("after-modal"));

    try runtime.requestFocus("modal-b");
    try std.testing.expectEqualStrings("modal-b", runtime.focused_id.?);
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("modal-a", runtime.focused_id.?);
    try runtime.keyInput(.{ .tab = .{ .reverse = true } });
    try std.testing.expectEqualStrings("modal-b", runtime.focused_id.?);

    try runtime.clearFocus();
    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("modal-a", runtime.focused_id.?);
}
