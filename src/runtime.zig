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
    focused_input_id: ?[]u8 = null,
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
        if (self.focused_input_id) |id| self.allocator.free(id);
        if (self.hovered_id) |id| self.allocator.free(id);
        if (self.pressed_id) |id| self.allocator.free(id);
        self.build_arena.deinit();
    }

    fn currentState(self: *const Runtime) State {
        return .{
            .input_text = self.input_text.items,
            .focused_input_id = self.focused_input_id,
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
            try self.setFocusedInput(id);
            _ = try self.setPressedId(null);
            try self.rebuild();
            try self.requestRepaint();
            return;
        }

        try self.setFocusedInput(null);
        if (keywork.hitTestClick(root, point)) |hit| {
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
            if (click_hit.callback) |callback| {
                try callback.call();
                needs_update = true;
            } else if (try self.app.click(click_hit.id)) {
                needs_update = true;
            }
        }

        if (needs_update) {
            try self.rebuild();
            try self.requestRepaint();
        }
    }

    fn setFocusedInput(self: *Runtime, id: ?[]const u8) !void {
        if (self.focused_input_id) |old_id| {
            if (id) |new_id| {
                if (std.mem.eql(u8, old_id, new_id)) return;
            }
            self.allocator.free(old_id);
            self.focused_input_id = null;
        }

        if (id) |new_id| {
            self.focused_input_id = try self.allocator.dupe(u8, new_id);
            log.info("focused text input {s}", .{new_id});
        }
    }

    pub fn keyInput(self: *Runtime, input: KeyInput) !void {
        if (self.focused_input_id == null) return;
        switch (input) {
            .text => |bytes| try self.input_text.appendSlice(self.allocator, bytes),
            .backspace => {
                popLastGrapheme(&self.input_text);
            },
            .enter => try self.setFocusedInput(null),
        }
        try self.rebuild();
        try self.requestRepaint();
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
            .interaction = .{ .hovered_id = self.hovered_id, .pressed_id = self.pressed_id },
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
