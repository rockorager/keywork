//! Runtime orchestration for Keywork applications.

const std = @import("std");
const uucode = @import("uucode");
const keywork = @import("core.zig");

const log = std.log.scoped(.keywork);

const AppContext = keywork.AppContext;
const AppHost = keywork.AppHost;
const Constraints = keywork.Constraints;
const BuildScope = keywork.BuildScope;
const DisplayList = keywork.DisplayList;
const Element = keywork.Element;
const CursorShape = keywork.CursorShape;
const KeyInput = keywork.KeyInput;
const Point = keywork.Point;
const PointerButtonState = keywork.PointerButtonState;
const RenderBackend = keywork.RenderBackend;
const RenderNode = keywork.RenderNode;
const RenderObjectNode = keywork.RenderObjectNode;
const Size = keywork.Size;
const desktop_settings = @import("desktop_settings.zig");
const event_loop = @import("event_loop.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    backend: RenderBackend,
    constraints: Constraints,
    app: AppHost,
    build_arena: std.heap.ArenaAllocator,
    color_scheme: desktop_settings.ColorScheme,
    input_text: std.ArrayList(u8) = .empty,
    focused_id: ?[]u8 = null,
    hovered_id: ?[]u8 = null,
    pressed_id: ?[]u8 = null,
    element_root: ?Element = null,
    render_object_root: ?RenderObjectNode = null,
    root: ?RenderNode = null,
    display_list: DisplayList = .{},
    repaint_pending: bool = false,
    rebuild_pending: bool = false,
    frame_pending: bool = false,
    rendering: bool = false,

    pub const State = AppContext;

    pub fn init(
        allocator: std.mem.Allocator,
        backend: RenderBackend,
        constraints: Constraints,
        app: AppHost,
        color_scheme: desktop_settings.ColorScheme,
    ) !Runtime {
        var self: Runtime = .{
            .allocator = allocator,
            .backend = backend,
            .constraints = constraints,
            .app = app,
            .build_arena = .init(allocator),
            .color_scheme = color_scheme,
        };
        errdefer self.deinit();
        try self.rebuild();
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.root) |*root| {
            keywork.destroyRenderTree(self.allocator, root);
            self.root = null;
        }
        if (self.render_object_root) |*render_object_root| {
            keywork.destroyRenderObjectTree(self.allocator, render_object_root);
            self.render_object_root = null;
        }
        if (self.element_root) |*element_root| {
            keywork.destroyElementTree(self.allocator, element_root);
            self.element_root = null;
        }
        self.display_list.deinit(self.allocator);
        self.input_text.deinit(self.allocator);
        if (self.focused_id) |id| self.allocator.free(id);
        if (self.hovered_id) |id| self.allocator.free(id);
        if (self.pressed_id) |id| self.allocator.free(id);
        self.build_arena.deinit();
    }

    fn currentState(self: *const Runtime) State {
        return .{
            .input_text = self.input_text.items,
            .window_width = self.constraints.max_width,
            .window_height = self.constraints.max_height,
            .color_scheme = self.color_scheme.name(),
        };
    }

    pub fn frameSize(self: *const Runtime) Size {
        return .{ .width = self.constraints.max_width, .height = self.constraints.max_height };
    }

    pub fn repaint(self: *Runtime) !void {
        try self.presentFrame();
    }

    pub fn requestRepaint(self: *Runtime) !void {
        self.repaint_pending = true;
        if (!self.frame_pending and !self.rendering) try self.presentFrame();
    }

    fn presentFrame(self: *Runtime) !void {
        if (self.rendering) {
            self.repaint_pending = true;
            return;
        }

        self.rendering = true;
        defer self.rendering = false;
        self.repaint_pending = false;
        if (self.rebuild_pending) {
            try self.rebuild();
            self.rebuild_pending = false;
        }

        const root = if (self.root) |*root| root else return error.NotBuilt;
        self.display_list.clearRetainingCapacity();
        const frame_size = self.frameSize();
        try self.display_list.fillRect(self.allocator, .{
            .x = 0,
            .y = 0,
            .width = frame_size.width,
            .height = frame_size.height,
        }, keywork.Theme.fromColorScheme(self.color_scheme.name()).color_scheme.surface);
        try keywork.paint(self.allocator, root, &self.display_list);
        self.frame_pending = try self.backend.present(.{
            .size = frame_size,
            .scale = 1,
            .damage = &.{.{ .x = 0, .y = 0, .width = frame_size.width, .height = frame_size.height }},
            .display_list = self.display_list.commands.items,
        });
    }

    fn frameDone(self: *Runtime) !void {
        self.frame_pending = false;
        if (self.repaint_pending) try self.presentFrame();
    }

    pub fn click(self: *Runtime, point: Point) !void {
        try self.pointerButton(point, .pressed);
        try self.pointerButton(point, .released);
    }

    pub fn pointerButton(self: *Runtime, point: Point, state: PointerButtonState) !void {
        switch (state) {
            .pressed => try self.pointerDown(point),
            .released => try self.pointerUp(point),
        }
    }

    fn pointerDown(self: *Runtime, point: Point) !void {
        const root = if (self.root) |*root| root else return error.NotBuilt;
        if (keywork.hitTestTextInput(root, point)) |id| {
            try self.setFocused(id);
            _ = try self.setPressedId(null);
            try self.rebuild();
            try self.requestRepaint();
            return;
        }

        try self.setFocused(null);
        if (keywork.hitTestClick(root, point)) |hit| {
            try self.setFocused(hit.id);
            if (try self.setPressedId(hit.id)) {
                try self.rebuild();
                try self.requestRepaint();
            }
        } else {
            log.info("pointer down on empty space at {d},{d}", .{ point.x, point.y });
            _ = try self.setPressedId(null);
            try self.rebuild();
            try self.requestRepaint();
        }
    }

    fn pointerUp(self: *Runtime, point: Point) !void {
        const root = if (self.root) |*root| root else return error.NotBuilt;
        const hit = keywork.hitTestClick(root, point);
        const should_activate = if (self.pressed_id) |pressed_id| blk: {
            const hit_id = if (hit) |click_hit| click_hit.id else break :blk false;
            break :blk std.mem.eql(u8, pressed_id, hit_id);
        } else false;

        var needs_update = try self.setPressedId(null);
        if (should_activate) {
            const click_hit = hit.?;
            log.info("clicked button {s} at {d},{d}", .{ click_hit.id, point.x, point.y });
            if (try self.activateClick(click_hit)) needs_update = true;
        }

        if (needs_update) {
            try self.rebuild();
            try self.requestRepaint();
        }
    }

    fn setFocused(self: *Runtime, id: ?[]const u8) !void {
        if (self.focused_id) |old_id| {
            if (id) |new_id| {
                if (std.mem.eql(u8, old_id, new_id)) return;
            }
            self.allocator.free(old_id);
            self.focused_id = null;
        }

        if (id) |new_id| {
            self.focused_id = try self.allocator.dupe(u8, new_id);
            log.info("focused {s}", .{new_id});
        }
    }

    pub fn keyInput(self: *Runtime, input: KeyInput) !void {
        if (try self.activateShortcut(input)) {
            try self.rebuild();
            try self.requestRepaint();
            return;
        }

        switch (input) {
            .tab => |tab| try self.focusNext(tab.reverse),
            .text => |bytes| {
                if (!self.focusedTargetIs(.text_input)) return;
                try self.input_text.appendSlice(self.allocator, bytes);
            },
            .backspace => {
                if (!self.focusedTargetIs(.text_input)) return;
                popLastGrapheme(&self.input_text);
            },
            .space => {
                const target = self.focusedTarget() orelse return;
                switch (target.kind) {
                    .text_input => try self.input_text.append(self.allocator, ' '),
                    .clickable => _ = try self.activateClick(.{ .id = target.id, .callback = target.callback }),
                    .focus => {},
                }
            },
            .enter => {
                const target = self.focusedTarget() orelse return;
                switch (target.kind) {
                    .text_input => try self.setFocused(null),
                    .clickable => _ = try self.activateClick(.{ .id = target.id, .callback = target.callback }),
                    .focus => {},
                }
            },
        }
        try self.rebuild();
        try self.requestRepaint();
    }

    fn activateShortcut(self: *Runtime, input: KeyInput) !bool {
        const shortcut_key = keywork.shortcutKeyForInput(input) orelse return false;
        if (self.focusedTargetIs(.text_input)) return false;
        const element_root = if (self.element_root) |*root| root else return false;
        const callback = if (self.focused_id) |focused_id|
            keywork.findFocusedShortcutAction(element_root, shortcut_key, focused_id) orelse keywork.findShortcutAction(element_root, shortcut_key) orelse return false
        else
            keywork.findShortcutAction(element_root, shortcut_key) orelse return false;
        try callback.call();
        return true;
    }

    fn focusedTarget(self: *Runtime) ?keywork.FocusTarget {
        const focused_id = self.focused_id orelse return null;
        const root = if (self.root) |*root| root else return null;
        return keywork.findFocusTarget(root, focused_id);
    }

    fn focusedTargetIs(self: *Runtime, kind: keywork.FocusTarget.Kind) bool {
        const target = self.focusedTarget() orelse return false;
        return target.kind == kind;
    }

    fn focusNext(self: *Runtime, reverse: bool) !void {
        const root = if (self.root) |*root| root else return error.NotBuilt;
        const targets = try keywork.collectFocusTargets(self.allocator, root);
        defer self.allocator.free(targets);
        if (targets.len == 0) return;

        const current_target = if (self.focused_id) |focused_id| findCollectedFocusTarget(targets, focused_id) else null;
        const active_scope_id = if (current_target) |target| target.scope_id else null;
        const next_index = nextFocusTargetIndex(targets, if (current_target) |target| target.id else null, active_scope_id, reverse) orelse return;

        try self.setFocused(targets[next_index].id);
    }

    fn findCollectedFocusTarget(targets: []const keywork.FocusTarget, id: []const u8) ?keywork.FocusTarget {
        for (targets) |target| {
            if (std.mem.eql(u8, target.id, id)) return target;
        }
        return null;
    }

    fn nextFocusTargetIndex(targets: []const keywork.FocusTarget, focused_id: ?[]const u8, scope_id: ?[]const u8, reverse: bool) ?usize {
        var first: ?usize = null;
        var last: ?usize = null;
        var previous_matching: ?usize = null;
        var previous_before_focused: ?usize = null;
        var focused_seen = focused_id == null;
        const filter_by_scope = focused_id != null;

        for (targets, 0..) |target, index| {
            if (filter_by_scope and !sameOptionalString(target.scope_id, scope_id)) continue;
            if (first == null) first = index;
            if (focused_id) |focused| {
                if (std.mem.eql(u8, target.id, focused)) {
                    focused_seen = true;
                    previous_before_focused = previous_matching;
                } else if (focused_seen and !reverse) {
                    return index;
                }
            } else if (!reverse) {
                return index;
            }
            previous_matching = index;
            last = index;
        }

        if (focused_id == null and reverse) return last;
        if (reverse) return previous_before_focused orelse last;
        return first;
    }

    fn sameOptionalString(a: ?[]const u8, b: ?[]const u8) bool {
        if (a) |a_value| {
            const b_value = b orelse return false;
            return std.mem.eql(u8, a_value, b_value);
        }
        return b == null;
    }

    fn activateClick(self: *Runtime, hit: keywork.ClickHit) !bool {
        _ = self;
        if (hit.callback) |callback| {
            try callback.call();
            return true;
        }
        return false;
    }

    pub fn cursorShape(self: *Runtime, point: Point) CursorShape {
        const root = if (self.root) |*root| root else return .default;
        return keywork.hitTestCursorShape(root, point);
    }

    pub fn pointerMove(self: *Runtime, point: ?Point) !void {
        const hit_id = if (point) |position| blk: {
            const root = if (self.root) |*root| root else return error.NotBuilt;
            break :blk if (keywork.hitTestClick(root, position)) |hit| hit.id else null;
        } else null;
        if (!try self.setHoveredId(hit_id)) return;
        try self.rebuild();
        try self.requestRepaint();
    }

    fn setHoveredId(self: *Runtime, id: ?[]const u8) !bool {
        if (self.hovered_id) |old_id| {
            if (id) |new_id| {
                if (std.mem.eql(u8, old_id, new_id)) return false;
            }
            self.allocator.free(old_id);
            self.hovered_id = null;
        } else if (id == null) {
            return false;
        }

        if (id) |new_id| {
            self.hovered_id = try self.allocator.dupe(u8, new_id);
        }
        return true;
    }

    fn setPressedId(self: *Runtime, id: ?[]const u8) !bool {
        if (self.pressed_id) |old_id| {
            if (id) |new_id| {
                if (std.mem.eql(u8, old_id, new_id)) return false;
            }
            self.allocator.free(old_id);
            self.pressed_id = null;
        } else if (id == null) {
            return false;
        }

        if (id) |new_id| {
            self.pressed_id = try self.allocator.dupe(u8, new_id);
        }
        return true;
    }

    pub fn waylandPointerButton(ctx: *anyopaque, point: Point, state: PointerButtonState) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.pointerButton(point, state) catch |err| {
            log.err("pointer button handling failed: {}", .{err});
        };
    }

    pub fn waylandCursorShape(ctx: *anyopaque, point: Point) CursorShape {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        return self.cursorShape(point);
    }

    pub fn waylandPointerMove(ctx: *anyopaque, point: ?Point) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.pointerMove(point) catch |err| {
            log.err("pointer motion failed: {}", .{err});
        };
    }

    pub fn waylandConfigure(ctx: *anyopaque, size: Size) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        if (size.width > 0 and size.height > 0) {
            self.constraints = .{ .max_width = size.width, .max_height = size.height };
        }
        if (self.rendering) {
            self.rebuild_pending = true;
            self.repaint_pending = true;
            return;
        }
        self.rebuild() catch |err| {
            log.err("configure rebuild failed: {}", .{err});
            return;
        };
        self.requestRepaint() catch |err| {
            log.err("configure repaint failed: {}", .{err});
        };
    }

    pub fn waylandFrameDone(ctx: *anyopaque) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.frameDone() catch |err| {
            log.err("frame repaint failed: {}", .{err});
        };
    }

    pub fn desktopSettingsChanged(ctx: *anyopaque, color_scheme: desktop_settings.ColorScheme) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        if (self.color_scheme == color_scheme) return;
        self.color_scheme = color_scheme;
        self.rebuild() catch |err| {
            log.err("desktop settings rebuild failed: {}", .{err});
            return;
        };
        self.requestRepaint() catch |err| {
            log.err("desktop settings repaint failed: {}", .{err});
        };
    }

    pub fn waylandKeyInput(ctx: *anyopaque, input: KeyInput) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.keyInput(input) catch |err| {
            log.err("key input failed: {}", .{err});
        };
    }

    pub fn timerTick(ctx: *anyopaque, _: *event_loop.EventLoop, expirations: u64) !void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        if (expirations == 0) return;
        if (try self.app.timer(expirations)) {
            try self.rebuild();
            try self.requestRepaint();
        }
    }

    pub fn fileChanged(
        ctx: *anyopaque,
        _: *event_loop.EventLoop,
        path: []const u8,
        mask: u32,
        _: ?[]const u8,
    ) !void {
        log.info("reload requested for {s} mask=0x{x}", .{ path, mask });
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        try self.rebuild();
        try self.requestRepaint();
    }

    fn rebuild(self: *Runtime) !void {
        if (self.root) |*old_root| {
            keywork.destroyRenderTree(self.allocator, old_root);
            self.root = null;
        }
        _ = self.build_arena.reset(.retain_capacity);
        const state = self.currentState();
        var build_scope: BuildScope = .{
            .allocator = self.build_arena.allocator(),
            .theme = keywork.Theme.fromColorScheme(state.color_scheme),
            .interaction = .{ .hovered_id = self.hovered_id, .pressed_id = self.pressed_id, .focused_id = self.focused_id },
        };

        var app_root = try self.app.buildWidget(&build_scope, state);
        if (self.element_root) |*element_root| {
            try keywork.updateElementTreeScoped(self.allocator, &build_scope, element_root, &app_root, self.constraints);
        } else {
            self.element_root = try keywork.buildElementTreeScoped(self.allocator, &build_scope, &app_root, self.constraints);
        }

        if (self.render_object_root) |*render_object_root| {
            try keywork.updateRenderObjectTree(self.allocator, render_object_root, &self.element_root.?);
        } else {
            self.render_object_root = try keywork.buildRenderObjectTree(self.allocator, &self.element_root.?);
        }

        var new_root = try keywork.buildRenderTreeFromElement(self.allocator, &self.element_root.?, self.constraints, self.backend);
        errdefer keywork.destroyRenderTree(self.allocator, &new_root);
        self.root = new_root;
    }
};

fn popLastGrapheme(bytes: *std.ArrayList(u8)) void {
    if (bytes.items.len == 0) return;

    var it = uucode.grapheme.utf8Iterator(bytes.items);
    var start: usize = 0;
    while (it.nextGrapheme()) |grapheme| {
        start = grapheme.start;
    }
    bytes.shrinkRetainingCapacity(start);
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

test "tab traversal focuses widgets and enter activates focused clickable" {
    const TestApp = struct {
        clicks: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, context: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const input = keywork.widgets.textInput("input", context.input_text, "placeholder");
            const button = try keywork.widgets.button(scope.allocator, "button", "Button", .{ .ptr = self, .call_fn = increment });
            const children = [_]keywork.Widget{ input, button };
            return keywork.widgets.column(scope.allocator, &children, 4);
        }

        fn increment(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.clicks += 1;
        }
    };

    const TestBackend = struct {
        fn backend(self: *@This()) RenderBackend {
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8) !Size {
            return keywork.TextMeasurer.fixed.measureText(value);
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
    try std.testing.expectEqualStrings("a", runtime.input_text.items);

    try runtime.keyInput(.{ .tab = .{} });
    try std.testing.expectEqualStrings("button", runtime.focused_id.?);
    try runtime.keyInput(.enter);
    try std.testing.expectEqual(@as(usize, 1), app.clicks);
    try runtime.keyInput(.space);
    try std.testing.expectEqual(@as(usize, 2), app.clicks);

    try runtime.keyInput(.{ .tab = .{ .reverse = true } });
    try std.testing.expectEqualStrings("input", runtime.focused_id.?);
    try runtime.keyInput(.space);
    try std.testing.expectEqualStrings("a ", runtime.input_text.items);
}

test "shortcut invokes ambient action outside text input focus" {
    const TestApp = struct {
        actions: usize = 0,

        fn host(self: *@This()) AppHost {
            return .{ .ptr = self, .vtable = &.{ .build_widget = buildWidget } };
        }

        fn buildWidget(ptr: *anyopaque, scope: *BuildScope, context: AppContext) !keywork.Widget {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const input = keywork.widgets.textInput("input", context.input_text, "placeholder");
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
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8) !Size {
            return keywork.TextMeasurer.fixed.measureText(value);
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
    try std.testing.expectEqualStrings(" ", runtime.input_text.items);
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
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8) !Size {
            return keywork.TextMeasurer.fixed.measureText(value);
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
            return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText } };
        }

        fn present(_: *anyopaque, _: RenderBackend.Frame) !bool {
            return false;
        }

        fn measureText(_: *anyopaque, value: []const u8) !Size {
            return keywork.TextMeasurer.fixed.measureText(value);
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
