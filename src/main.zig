//! Keywork MVP: widget descriptions, layout, display-list painting, and a
//! backend boundary that can start on CPU and grow a GPU implementation later.

const std = @import("std");
const uucode = @import("uucode");

const log = std.log.scoped(.keywork);

pub const event_loop = @import("event_loop.zig");
pub const lua_app = @import("lua_app.zig");
pub const wayland_shm = @import("wayland_shm.zig");

pub const Color = packed struct(u32) {
    b: u8,
    g: u8,
    r: u8,
    a: u8,

    pub fn argb(a: u8, r: u8, g: u8, b: u8) Color {
        return .{ .a = a, .r = r, .g = g, .b = b };
    }
};

pub const colors = struct {
    pub const transparent: Color = Color.argb(0x00, 0x00, 0x00, 0x00);
    pub const white: Color = Color.argb(0xff, 0xff, 0xff, 0xff);
    pub const black: Color = Color.argb(0xff, 0x00, 0x00, 0x00);
    pub const ink: Color = Color.argb(0xff, 0x1b, 0x1b, 0x1f);
    pub const panel: Color = Color.argb(0xff, 0xf5, 0xf3, 0xef);
    pub const accent: Color = Color.argb(0xff, 0x6d, 0x4a, 0xff);
};

pub const Size = struct {
    width: f32,
    height: f32,
};

pub const Point = struct {
    x: f32,
    y: f32,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn contains(self: Rect, point: Point) bool {
        return point.x >= self.x and point.y >= self.y and
            point.x < self.x + self.width and point.y < self.y + self.height;
    }

    pub fn size(self: Rect) Size {
        return .{ .width = self.width, .height = self.height };
    }
};

pub const EdgeInsets = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub fn all(value: f32) EdgeInsets {
        return .{ .left = value, .top = value, .right = value, .bottom = value };
    }

    fn horizontal(self: EdgeInsets) f32 {
        return self.left + self.right;
    }

    fn vertical(self: EdgeInsets) f32 {
        return self.top + self.bottom;
    }
};

pub const Constraints = struct {
    max_width: f32,
    max_height: f32,

    fn inset(self: Constraints, padding: EdgeInsets) Constraints {
        return .{
            .max_width = @max(0, self.max_width - padding.horizontal()),
            .max_height = @max(0, self.max_height - padding.vertical()),
        };
    }

    fn clamp(self: Constraints, size_value: Size) Size {
        return .{
            .width = @min(size_value.width, self.max_width),
            .height = @min(size_value.height, self.max_height),
        };
    }
};

pub const Widget = union(enum) {
    text: Text,
    button: Button,
    text_input: TextInput,
    row: Children,
    column: Children,
    padding: Padding,
    center: Child,

    pub const Text = struct {
        value: []const u8,
        color: Color = colors.ink,
    };

    pub const Button = struct {
        id: []const u8,
        label: []const u8,
        background: Color = colors.accent,
    };

    pub const TextInput = struct {
        id: []const u8,
        value: []const u8,
        placeholder: []const u8,
        focused: bool = false,
    };

    pub const Children = struct {
        children: []const Widget,
        gap: f32 = 0,
    };

    pub const Padding = struct {
        insets: EdgeInsets,
        child: *const Widget,
    };

    pub const Child = struct {
        child: *const Widget,
    };
};

pub const RenderNode = struct {
    kind: Kind,
    rect: Rect,
    text: ?[]const u8 = null,
    button_id: ?[]const u8 = null,
    text_input_id: ?[]const u8 = null,
    foreground: Color = colors.ink,
    background: Color = colors.transparent,
    placeholder: ?[]const u8 = null,
    focused: bool = false,
    caret_x: ?f32 = null,
    children: []RenderNode = &.{},

    pub const Kind = enum {
        text,
        button,
        text_input,
        row,
        column,
        padding,
        center,
    };
};

pub const PaintCommand = union(enum) {
    fill_rect: FillRect,
    text: TextRun,

    pub const FillRect = struct {
        rect: Rect,
        color: Color,
    };

    pub const TextRun = struct {
        origin: Point,
        value: []const u8,
        color: Color,
    };
};

pub const DisplayList = struct {
    commands: std.ArrayList(PaintCommand) = .empty,

    pub fn deinit(self: *DisplayList, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *DisplayList) void {
        self.commands.clearRetainingCapacity();
    }

    pub fn fillRect(self: *DisplayList, allocator: std.mem.Allocator, rect: Rect, color: Color) !void {
        try self.commands.append(allocator, .{ .fill_rect = .{ .rect = rect, .color = color } });
    }

    pub fn text(self: *DisplayList, allocator: std.mem.Allocator, origin: Point, value: []const u8, color: Color) !void {
        try self.commands.append(allocator, .{ .text = .{ .origin = origin, .value = value, .color = color } });
    }
};

pub const RenderBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        present: *const fn (ptr: *anyopaque, frame: Frame) anyerror!void,
        measure_text: *const fn (ptr: *anyopaque, value: []const u8) anyerror!Size,
    };

    pub const Frame = struct {
        size: Size,
        scale: f32,
        damage: []const Rect,
        display_list: []const PaintCommand,
    };

    pub fn present(self: RenderBackend, frame: Frame) !void {
        try self.vtable.present(self.ptr, frame);
    }

    pub fn measureText(self: RenderBackend, value: []const u8) !Size {
        return self.vtable.measure_text(self.ptr, value);
    }
};

pub const TextMeasurer = union(enum) {
    fixed,
    backend: RenderBackend,

    pub fn measureText(self: TextMeasurer, value: []const u8) !Size {
        return switch (self) {
            .fixed => fixedMeasureText(value),
            .backend => |backend| backend.measureText(value),
        };
    }
};

pub const LogBackend = struct {
    writer: *std.Io.Writer,

    pub fn backend(self: *LogBackend) RenderBackend {
        return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText } };
    }

    fn present(ptr: *anyopaque, frame: RenderBackend.Frame) !void {
        const self: *LogBackend = @ptrCast(@alignCast(ptr));
        try self.writer.print("frame {d}x{d} scale {d} commands {d}\n", .{
            frame.size.width,
            frame.size.height,
            frame.scale,
            frame.display_list.len,
        });
        for (frame.display_list) |command| {
            switch (command) {
                .fill_rect => |fill| try self.writer.print(
                    "fill_rect x={d} y={d} w={d} h={d} color=#{x:0>8}\n",
                    .{ fill.rect.x, fill.rect.y, fill.rect.width, fill.rect.height, @as(u32, @bitCast(fill.color)) },
                ),
                .text => |run| try self.writer.print(
                    "text x={d} y={d} value=\"{s}\" color=#{x:0>8}\n",
                    .{ run.origin.x, run.origin.y, run.value, @as(u32, @bitCast(run.color)) },
                ),
            }
        }
    }

    fn measureText(_: *anyopaque, value: []const u8) !Size {
        return fixedMeasureText(value);
    }
};

const text_height = 16;
const text_width = 8;
const button_horizontal_padding = 14;
const button_vertical_padding = 8;
const input_horizontal_padding = 10;
const input_vertical_padding = 8;
const input_min_width = 220;
const LayoutError = anyerror;

pub const KeyInput = union(enum) {
    text: []const u8,
    backspace,
    enter,
};

pub fn buildRenderTree(allocator: std.mem.Allocator, widget: *const Widget, constraints: Constraints) !RenderNode {
    return layout(allocator, widget, constraints, .{ .x = 0, .y = 0 }, .fixed);
}

pub fn buildRenderTreeMeasured(
    allocator: std.mem.Allocator,
    widget: *const Widget,
    constraints: Constraints,
    backend: RenderBackend,
) !RenderNode {
    return layout(allocator, widget, constraints, .{ .x = 0, .y = 0 }, .{ .backend = backend });
}

pub fn destroyRenderTree(allocator: std.mem.Allocator, node: *RenderNode) void {
    for (node.children) |*child| {
        destroyRenderTree(allocator, child);
    }
    allocator.free(node.children);
    node.children = &.{};
}

pub fn paint(allocator: std.mem.Allocator, node: *const RenderNode, display_list: *DisplayList) !void {
    switch (node.kind) {
        .button => {
            try display_list.fillRect(allocator, node.rect, node.background);
            if (node.text) |value| {
                try display_list.text(allocator, .{
                    .x = node.rect.x + button_horizontal_padding,
                    .y = node.rect.y + button_vertical_padding,
                }, value, node.foreground);
            }
        },
        .text_input => {
            try display_list.fillRect(allocator, node.rect, colors.white);
            try paintBorder(allocator, display_list, node.rect, if (node.focused) colors.accent else colors.ink);
            const value = node.text orelse "";
            const visible_text = if (value.len > 0) value else node.placeholder orelse "";
            const text_color = if (value.len > 0) node.foreground else Color.argb(0xff, 0x77, 0x77, 0x7d);
            try display_list.text(allocator, .{
                .x = node.rect.x + input_horizontal_padding,
                .y = node.rect.y + input_vertical_padding,
            }, visible_text, text_color);
            if (node.focused) {
                const caret_x = node.caret_x orelse node.rect.x + input_horizontal_padding;
                try display_list.fillRect(allocator, .{
                    .x = caret_x,
                    .y = node.rect.y + input_vertical_padding,
                    .width = 1,
                    .height = @max(1, node.rect.height - input_vertical_padding * 2),
                }, colors.ink);
            }
        },
        .text => if (node.text) |value| {
            try display_list.text(allocator, .{ .x = node.rect.x, .y = node.rect.y }, value, node.foreground);
        },
        else => {},
    }

    for (node.children) |*child| {
        try paint(allocator, child, display_list);
    }
}

fn paintBorder(allocator: std.mem.Allocator, display_list: *DisplayList, rect: Rect, color: Color) !void {
    try display_list.fillRect(allocator, .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = 1 }, color);
    try display_list.fillRect(allocator, .{ .x = rect.x, .y = rect.y + rect.height - 1, .width = rect.width, .height = 1 }, color);
    try display_list.fillRect(allocator, .{ .x = rect.x, .y = rect.y, .width = 1, .height = rect.height }, color);
    try display_list.fillRect(allocator, .{ .x = rect.x + rect.width - 1, .y = rect.y, .width = 1, .height = rect.height }, color);
}

pub fn hitTestButton(node: *const RenderNode, point: Point) ?[]const u8 {
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (hitTestButton(&node.children[index], point)) |id| return id;
    }

    if (node.kind == .button and node.rect.contains(point)) {
        return node.button_id;
    }
    return null;
}

pub fn hitTestTextInput(node: *const RenderNode, point: Point) ?[]const u8 {
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (hitTestTextInput(&node.children[index], point)) |id| return id;
    }

    if (node.kind == .text_input and node.rect.contains(point)) {
        return node.text_input_id;
    }
    return null;
}

fn layout(allocator: std.mem.Allocator, widget: *const Widget, constraints: Constraints, origin: Point, measurer: TextMeasurer) LayoutError!RenderNode {
    switch (widget.*) {
        .text => |text_widget| {
            const measured = try measurer.measureText(text_widget.value);
            const size_value = constraints.clamp(measured);
            return .{
                .kind = .text,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .text = text_widget.value,
                .foreground = text_widget.color,
            };
        },
        .button => |button_widget| {
            const label_size = try measurer.measureText(button_widget.label);
            const requested = Size{
                .width = label_size.width + button_horizontal_padding * 2,
                .height = label_size.height + button_vertical_padding * 2,
            };
            const size_value = constraints.clamp(requested);
            return .{
                .kind = .button,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .text = button_widget.label,
                .button_id = button_widget.id,
                .foreground = colors.white,
                .background = button_widget.background,
            };
        },
        .text_input => |input_widget| {
            const text_value = if (input_widget.value.len > 0) input_widget.value else input_widget.placeholder;
            const measured = try measurer.measureText(text_value);
            const value_size = try measurer.measureText(input_widget.value);
            const requested = Size{
                .width = @max(input_min_width, measured.width + input_horizontal_padding * 2),
                .height = measured.height + input_vertical_padding * 2,
            };
            const size_value = constraints.clamp(requested);
            return .{
                .kind = .text_input,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .text = input_widget.value,
                .text_input_id = input_widget.id,
                .foreground = colors.ink,
                .background = colors.white,
                .placeholder = input_widget.placeholder,
                .focused = input_widget.focused,
                .caret_x = origin.x + input_horizontal_padding + value_size.width,
            };
        },
        .padding => |padding_widget| {
            var child = try layout(allocator, padding_widget.child, constraints.inset(padding_widget.insets), .{
                .x = origin.x + padding_widget.insets.left,
                .y = origin.y + padding_widget.insets.top,
            }, measurer);
            errdefer destroyRenderTree(allocator, &child);

            const children = try allocator.alloc(RenderNode, 1);
            children[0] = child;
            return .{
                .kind = .padding,
                .rect = .{
                    .x = origin.x,
                    .y = origin.y,
                    .width = @min(child.rect.width + padding_widget.insets.horizontal(), constraints.max_width),
                    .height = @min(child.rect.height + padding_widget.insets.vertical(), constraints.max_height),
                },
                .children = children,
            };
        },
        .center => |center_widget| {
            var child = try layout(allocator, center_widget.child, constraints, origin, measurer);
            errdefer destroyRenderTree(allocator, &child);

            child.rect.x = origin.x + @max(0, constraints.max_width - child.rect.width) / 2;
            child.rect.y = origin.y + @max(0, constraints.max_height - child.rect.height) / 2;
            translateChildren(&child, child.rect.x - origin.x, child.rect.y - origin.y);

            const children = try allocator.alloc(RenderNode, 1);
            children[0] = child;
            return .{
                .kind = .center,
                .rect = .{ .x = origin.x, .y = origin.y, .width = constraints.max_width, .height = constraints.max_height },
                .children = children,
            };
        },
        .column => |column_widget| return layoutLinear(allocator, .column, column_widget, constraints, origin, measurer),
        .row => |row_widget| return layoutLinear(allocator, .row, row_widget, constraints, origin, measurer),
    }
}

fn layoutLinear(
    allocator: std.mem.Allocator,
    comptime kind: RenderNode.Kind,
    widget: Widget.Children,
    constraints: Constraints,
    origin: Point,
    measurer: TextMeasurer,
) LayoutError!RenderNode {
    std.debug.assert(kind == .row or kind == .column);

    const children = try allocator.alloc(RenderNode, widget.children.len);
    var initialized: usize = 0;
    errdefer {
        for (children[0..initialized]) |*child| {
            destroyRenderTree(allocator, child);
        }
        allocator.free(children);
    }

    var cursor = origin;
    var width: f32 = 0;
    var height: f32 = 0;
    for (widget.children, 0..) |*child_widget, index| {
        const remaining = switch (kind) {
            .row => Constraints{ .max_width = @max(0, constraints.max_width - (cursor.x - origin.x)), .max_height = constraints.max_height },
            .column => Constraints{ .max_width = constraints.max_width, .max_height = @max(0, constraints.max_height - (cursor.y - origin.y)) },
            else => unreachable,
        };
        children[index] = try layout(allocator, child_widget, remaining, cursor, measurer);
        initialized += 1;

        switch (kind) {
            .row => {
                cursor.x += children[index].rect.width + widget.gap;
                width += children[index].rect.width;
                if (index + 1 < widget.children.len) width += widget.gap;
                height = @max(height, children[index].rect.height);
            },
            .column => {
                cursor.y += children[index].rect.height + widget.gap;
                height += children[index].rect.height;
                if (index + 1 < widget.children.len) height += widget.gap;
                width = @max(width, children[index].rect.width);
            },
            else => unreachable,
        }
    }

    const size_value = constraints.clamp(.{ .width = width, .height = height });
    return .{
        .kind = kind,
        .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
        .children = children,
    };
}

fn fixedMeasureText(value: []const u8) Size {
    return .{ .width = @as(f32, @floatFromInt(value.len)) * text_width, .height = text_height };
}

fn translateChildren(node: *RenderNode, dx: f32, dy: f32) void {
    for (node.children) |*child| {
        child.rect.x += dx;
        child.rect.y += dy;
        translateChildren(child, dx, dy);
    }
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    backend: RenderBackend,
    constraints: Constraints,
    lua: *lua_app.App,
    widget_arena: std.heap.ArenaAllocator,
    state: DemoState = .{},
    input_text: std.ArrayList(u8) = .empty,
    focused_input_id: ?[]u8 = null,
    root: ?RenderNode = null,
    display_list: DisplayList = .{},

    pub const State = struct {
        button_pressed: bool = false,
        pulse: bool = false,
        input_text: []const u8 = "",
        focused_input_id: ?[]const u8 = null,
    };
    const DemoState = State;

    pub fn init(allocator: std.mem.Allocator, backend: RenderBackend, constraints: Constraints, lua: *lua_app.App) !Runtime {
        var self: Runtime = .{
            .allocator = allocator,
            .backend = backend,
            .constraints = constraints,
            .lua = lua,
            .widget_arena = .init(allocator),
        };
        errdefer self.deinit();
        try self.rebuild();
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.root) |*root| {
            destroyRenderTree(self.allocator, root);
            self.root = null;
        }
        self.display_list.deinit(self.allocator);
        self.input_text.deinit(self.allocator);
        if (self.focused_input_id) |id| self.allocator.free(id);
        self.widget_arena.deinit();
    }

    fn currentState(self: *const Runtime) State {
        return .{
            .button_pressed = self.state.button_pressed,
            .pulse = self.state.pulse,
            .input_text = self.input_text.items,
            .focused_input_id = self.focused_input_id,
        };
    }

    pub fn frameSize(self: *const Runtime) Size {
        if (self.root) |root| return root.rect.size();
        return .{ .width = self.constraints.max_width, .height = self.constraints.max_height };
    }

    pub fn repaint(self: *Runtime) !void {
        const root = if (self.root) |*root| root else return error.NotBuilt;
        self.display_list.clearRetainingCapacity();
        try paint(self.allocator, root, &self.display_list);
        try self.backend.present(.{
            .size = root.rect.size(),
            .scale = 1,
            .damage = &.{root.rect},
            .display_list = self.display_list.commands.items,
        });
    }

    pub fn click(self: *Runtime, point: Point) !void {
        const root = if (self.root) |*root| root else return error.NotBuilt;
        if (hitTestTextInput(root, point)) |id| {
            try self.setFocusedInput(id);
            try self.rebuild();
            try self.repaint();
            return;
        }

        try self.setFocusedInput(null);
        if (hitTestButton(root, point)) |id| {
            log.info("clicked button {s} at {d},{d}", .{ id, point.x, point.y });
            if (std.mem.eql(u8, id, "hello")) {
                self.state.button_pressed = !self.state.button_pressed;
                try self.rebuild();
                try self.repaint();
            }
        } else {
            log.info("clicked empty space at {d},{d}", .{ point.x, point.y });
            try self.rebuild();
            try self.repaint();
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
        try self.repaint();
    }

    pub fn waylandClick(ctx: *anyopaque, point: Point) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.click(point) catch |err| {
            log.err("click handling failed: {}", .{err});
        };
    }

    pub fn waylandScaleChanged(ctx: *anyopaque) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.rebuild() catch |err| {
            log.err("scale rebuild failed: {}", .{err});
            return;
        };
        self.repaint() catch |err| {
            log.err("scale repaint failed: {}", .{err});
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
        self.state.pulse = !self.state.pulse;
        try self.rebuild();
        try self.repaint();
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
        try self.repaint();
    }

    fn rebuild(self: *Runtime) !void {
        if (self.root) |*old_root| {
            destroyRenderTree(self.allocator, old_root);
            self.root = null;
        }
        _ = self.widget_arena.reset(.retain_capacity);

        var lua_root = try self.lua.buildWidget(self.widget_arena.allocator(), self.currentState());
        var new_root = try buildRenderTreeMeasured(self.allocator, &lua_root, self.constraints, self.backend);
        errdefer destroyRenderTree(self.allocator, &new_root);
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

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();
    const use_wayland = shouldUseWayland(init);
    const constraints: Constraints = .{ .max_width = 640, .max_height = 480 };
    var lua = try lua_app.App.init(allocator, "main.lua");
    defer lua.deinit();

    if (use_wayland) {
        var backend = try wayland_shm.Backend.create(allocator, .{
            .title = "Keywork MVP",
            .width = try positiveU31(constraints.max_width),
            .height = try positiveU31(constraints.max_height),
        });
        defer backend.destroy();

        var runtime = try Runtime.init(allocator, backend.renderBackend(), constraints, &lua);
        defer runtime.deinit();
        backend.setClickHandler(&runtime, Runtime.waylandClick);
        backend.setRepaintHandler(&runtime, Runtime.waylandScaleChanged);
        backend.setKeyHandler(&runtime, Runtime.waylandKeyInput);
        try runtime.repaint();

        var loop = try event_loop.EventLoop.init(allocator);
        defer loop.deinit();
        try loop.setWayland(.{
            .fd = backend.eventLoopFd(),
            .ctx = backend,
            .prepare = wayland_shm.Backend.eventLoopPrepare,
            .finish = wayland_shm.Backend.eventLoopFinish,
        });
        try backend.installKeyRepeat(&loop);
        defer backend.uninstallKeyRepeat();
        try loop.addRepeatingTimer(1000, &runtime, Runtime.timerTick);
        loop.addFileWatch("main.lua", &runtime, Runtime.fileChanged) catch |err| {
            if (err != error.FileWatchNotFound) log.warn("main.lua watch not installed: {}", .{err});
        };
        try loop.run();
        return;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    var backend: LogBackend = .{ .writer = &stdout_writer.interface };
    var runtime = try Runtime.init(allocator, backend.backend(), constraints, &lua);
    defer runtime.deinit();
    try runtime.repaint();

    const root = if (runtime.root) |*root| root else return error.NotBuilt;
    if (hitTestButton(root, .{ .x = 40, .y = 140 })) |id| {
        try stdout_writer.interface.print("hit button {s}\n", .{id});
    } else {
        try stdout_writer.interface.print("hit nothing\n", .{});
    }

    log.debug("frame rendered", .{});
}

fn shouldUseWayland(init: std.process.Init) bool {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--wayland")) return true;
    }
    return false;
}

fn positiveU31(value: f32) !u31 {
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidFrameSize;
    const rounded = @ceil(value);
    if (rounded > @as(f32, @floatFromInt(std.math.maxInt(u31)))) return error.InvalidFrameSize;
    return @intFromFloat(rounded);
}

test "layout, paint, and hit test a padded column" {
    const allocator = std.testing.allocator;

    const title: Widget = .{ .text = .{ .value = "Title" } };
    const button: Widget = .{ .button = .{ .id = "ok", .label = "OK" } };
    const children = [_]Widget{ title, button };
    const column: Widget = .{ .column = .{ .children = &children, .gap = 4 } };
    const padded: Widget = .{ .padding = .{ .insets = EdgeInsets.all(10), .child = &column } };

    var root = try buildRenderTree(allocator, &padded, .{ .max_width = 200, .max_height = 120 });
    defer destroyRenderTree(allocator, &root);

    try std.testing.expectEqual(@as(RenderNode.Kind, .padding), root.kind);
    try std.testing.expectEqual(@as(f32, 64), root.rect.width);
    try std.testing.expectEqual(@as(f32, 72), root.rect.height);

    var display_list: DisplayList = .{};
    defer display_list.deinit(allocator);
    try paint(allocator, &root, &display_list);

    try std.testing.expectEqual(@as(usize, 3), display_list.commands.items.len);
    try std.testing.expectEqualStrings("ok", hitTestButton(&root, .{ .x = 25, .y = 35 }).?);
    try std.testing.expect(hitTestButton(&root, .{ .x = 2, .y = 2 }) == null);
}

test "center moves descendants" {
    const allocator = std.testing.allocator;

    const button: Widget = .{ .button = .{ .id = "centered", .label = "Run" } };
    const center: Widget = .{ .center = .{ .child = &button } };

    var root = try buildRenderTree(allocator, &center, .{ .max_width = 100, .max_height = 80 });
    defer destroyRenderTree(allocator, &root);

    try std.testing.expectEqual(@as(f32, 24), root.children[0].rect.x);
    try std.testing.expectEqual(@as(f32, 24), root.children[0].rect.y);
    try std.testing.expectEqualStrings("centered", hitTestButton(&root, .{ .x = 30, .y = 30 }).?);
}
