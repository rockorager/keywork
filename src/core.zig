//! Core Keywork framework types, element/render trees, layout, painting, and hit testing.

const std = @import("std");

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
    keyed: Keyed,
    text: Text,
    box: Box,
    clickable: Clickable,
    text_input: TextInput,
    row: Children,
    column: Children,
    padding: Padding,
    center: Child,
    component: Component,
    stateful: Stateful,
    element: CustomElement,
    render_object: RenderObject,

    pub fn alloc(allocator: std.mem.Allocator, widget: Widget) !*Widget {
        const result = try allocator.create(Widget);
        result.* = widget;
        return result;
    }

    pub fn allocSlice(allocator: std.mem.Allocator, items: []const Widget) ![]Widget {
        return allocator.dupe(Widget, items);
    }

    pub const Key = union(enum) {
        string: []const u8,
        integer: u64,
    };

    pub const Keyed = struct {
        key: Key,
        child: *const Widget,
    };

    pub const Text = struct {
        value: []const u8,
        color: Color = colors.ink,
    };

    pub const Box = struct {
        child: *const Widget,
        background: Color = colors.transparent,
    };

    pub const Clickable = struct {
        id: []const u8,
        child: *const Widget,
        on_click: ?Callback = null,
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

    pub const Callback = struct {
        ptr: *anyopaque,
        call_fn: *const fn (ptr: *anyopaque) anyerror!void,

        pub fn call(self: Callback) !void {
            try self.call_fn(self.ptr);
        }
    };

    pub const BuildContext = struct {
        constraints: Constraints,
    };

    pub const Component = struct {
        ptr: *const anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            build: *const fn (ptr: *const anyopaque, allocator: std.mem.Allocator, context: BuildContext) anyerror!Widget,
        };

        pub fn build(self: Component, allocator: std.mem.Allocator, context: BuildContext) !Widget {
            return self.vtable.build(self.ptr, allocator, context);
        }
    };

    pub const Stateful = struct {
        ptr: *const anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            create_state: *const fn (ptr: *const anyopaque, allocator: std.mem.Allocator) anyerror!*anyopaque,
            update: *const fn (ptr: *const anyopaque, state: *anyopaque, allocator: std.mem.Allocator, context: BuildContext) anyerror!void,
            build: *const fn (ptr: *const anyopaque, state: *anyopaque, allocator: std.mem.Allocator, context: BuildContext) anyerror!Widget,
            destroy_state: *const fn (ptr: *const anyopaque, state: *anyopaque, allocator: std.mem.Allocator) void,
        };

        pub fn createState(self: Stateful, allocator: std.mem.Allocator) !*anyopaque {
            return self.vtable.create_state(self.ptr, allocator);
        }

        pub fn update(self: Stateful, state: *anyopaque, allocator: std.mem.Allocator, context: BuildContext) !void {
            try self.vtable.update(self.ptr, state, allocator, context);
        }

        pub fn build(self: Stateful, state: *anyopaque, allocator: std.mem.Allocator, context: BuildContext) !Widget {
            return self.vtable.build(self.ptr, state, allocator, context);
        }

        pub fn destroyState(self: Stateful, state: *anyopaque, allocator: std.mem.Allocator) void {
            self.vtable.destroy_state(self.ptr, state, allocator);
        }
    };

    pub const CustomElement = struct {
        ptr: *const anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            build: *const fn (ptr: *const anyopaque, allocator: std.mem.Allocator, context: BuildContext) anyerror!Element,
        };

        pub fn build(self: CustomElement, allocator: std.mem.Allocator, context: BuildContext) !Element {
            return self.vtable.build(self.ptr, allocator, context);
        }
    };

    pub const RenderObject = struct {
        ptr: *const anyopaque,
        vtable: *const VTable,

        pub const LayoutContext = struct {
            constraints: Constraints,
            measurer: TextMeasurer,
        };

        pub const PaintContext = struct {
            allocator: std.mem.Allocator,
            rect: Rect,
            display_list: *DisplayList,
        };

        pub const VTable = struct {
            layout: *const fn (ptr: *const anyopaque, context: LayoutContext) anyerror!Size,
            paint: *const fn (ptr: *const anyopaque, context: PaintContext) anyerror!void,
            hit_test: ?*const fn (ptr: *const anyopaque, rect: Rect, point: Point) ?[]const u8 = null,
        };

        pub fn layout(self: RenderObject, context: LayoutContext) !Size {
            return self.vtable.layout(self.ptr, context);
        }

        pub fn paint(self: RenderObject, context: PaintContext) !void {
            try self.vtable.paint(self.ptr, context);
        }

        pub fn hitTest(self: RenderObject, rect: Rect, point: Point) ?[]const u8 {
            const hit_test = self.vtable.hit_test orelse return null;
            return hit_test(self.ptr, rect, point);
        }
    };
};

pub const widgets = struct {
    pub fn text(value: []const u8) Widget {
        return .{ .text = .{ .value = value } };
    }

    pub fn coloredText(value: []const u8, color: Color) Widget {
        return .{ .text = .{ .value = value, .color = color } };
    }

    pub fn box(allocator: std.mem.Allocator, child: Widget, background: Color) !Widget {
        return .{ .box = .{ .child = try Widget.alloc(allocator, child), .background = background } };
    }

    pub fn clickable(allocator: std.mem.Allocator, id: []const u8, child: Widget) !Widget {
        return .{ .clickable = .{ .id = id, .child = try Widget.alloc(allocator, child) } };
    }

    pub fn textInput(id: []const u8, value: []const u8, placeholder: []const u8, focused: bool) Widget {
        return .{ .text_input = .{ .id = id, .value = value, .placeholder = placeholder, .focused = focused } };
    }

    pub fn row(allocator: std.mem.Allocator, children: []const Widget, gap: f32) !Widget {
        return .{ .row = .{ .children = try Widget.allocSlice(allocator, children), .gap = gap } };
    }

    pub fn column(allocator: std.mem.Allocator, children: []const Widget, gap: f32) !Widget {
        return .{ .column = .{ .children = try Widget.allocSlice(allocator, children), .gap = gap } };
    }

    pub fn padding(allocator: std.mem.Allocator, insets: EdgeInsets, child: Widget) !Widget {
        return .{ .padding = .{ .insets = insets, .child = try Widget.alloc(allocator, child) } };
    }

    pub fn center(allocator: std.mem.Allocator, child: Widget) !Widget {
        return .{ .center = .{ .child = try Widget.alloc(allocator, child) } };
    }

    pub fn keyed(allocator: std.mem.Allocator, key: Widget.Key, child: Widget) !Widget {
        return .{ .keyed = .{ .key = key, .child = try Widget.alloc(allocator, child) } };
    }
};

pub const Element = struct {
    kind: Kind,
    widget: Widget,
    key: ?Widget.Key = null,
    state: ?*anyopaque = null,
    children: []Element = &.{},

    pub const Kind = enum {
        keyed,
        text,
        box,
        clickable,
        text_input,
        row,
        column,
        padding,
        center,
        component,
        stateful,
        element,
        render_object,
    };
};

pub const RenderObjectNode = struct {
    kind: Element.Kind,
    key: ?Widget.Key = null,
    render_object: ?Widget.RenderObject = null,
    children: []RenderObjectNode = &.{},
};

pub const RenderNode = struct {
    kind: Kind,
    rect: Rect,
    text: ?[]const u8 = null,
    clickable_id: ?[]const u8 = null,
    click_callback: ?Widget.Callback = null,
    text_input_id: ?[]const u8 = null,
    render_object: ?Widget.RenderObject = null,
    foreground: Color = colors.ink,
    background: Color = colors.transparent,
    placeholder: ?[]const u8 = null,
    focused: bool = false,
    caret_x: ?f32 = null,
    children: []RenderNode = &.{},

    pub const Kind = enum {
        keyed,
        text,
        box,
        clickable,
        text_input,
        row,
        column,
        padding,
        center,
        component,
        stateful,
        element,
        render_object,
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
        present: *const fn (ptr: *anyopaque, frame: Frame) anyerror!bool,
        measure_text: *const fn (ptr: *anyopaque, value: []const u8) anyerror!Size,
    };

    pub const Frame = struct {
        size: Size,
        scale: f32,
        damage: []const Rect,
        display_list: []const PaintCommand,
    };

    pub fn present(self: RenderBackend, frame: Frame) !bool {
        return self.vtable.present(self.ptr, frame);
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

    fn present(ptr: *anyopaque, frame: RenderBackend.Frame) !bool {
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
        return false;
    }

    fn measureText(_: *anyopaque, value: []const u8) !Size {
        return fixedMeasureText(value);
    }
};

const text_height = 16;
const text_width = 8;
const input_horizontal_padding = 10;
const input_vertical_padding = 8;
const input_min_width = 220;
const LayoutError = anyerror;

pub const KeyInput = union(enum) {
    text: []const u8,
    backspace,
    enter,
};

pub const CursorShape = enum {
    default,
    pointer,
    text,
};

pub const AppContext = struct {
    button_pressed: bool = false,
    pulse: bool = false,
    input_text: []const u8 = "",
    focused_input_id: ?[]const u8 = null,
    window_width: f32 = 0,
    window_height: f32 = 0,
    color_scheme: []const u8 = "no-preference",
};

pub const AppHost = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        build_widget: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, context: AppContext) anyerror!Widget,
        click: ?*const fn (ptr: *anyopaque, id: []const u8) anyerror!bool = null,
        timer: ?*const fn (ptr: *anyopaque, expirations: u64) anyerror!bool = null,
    };

    pub fn buildWidget(self: AppHost, allocator: std.mem.Allocator, context: AppContext) !Widget {
        return self.vtable.build_widget(self.ptr, allocator, context);
    }

    pub fn click(self: AppHost, id: []const u8) !bool {
        const click_fn = self.vtable.click orelse return false;
        return click_fn(self.ptr, id);
    }

    pub fn timer(self: AppHost, expirations: u64) !bool {
        const timer_fn = self.vtable.timer orelse return false;
        return timer_fn(self.ptr, expirations);
    }
};

pub fn buildRenderTree(allocator: std.mem.Allocator, widget: *const Widget, constraints: Constraints) !RenderNode {
    var element = try buildElementTree(allocator, widget, constraints);
    defer destroyElementTree(allocator, &element);
    return layoutElement(allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
}

pub fn buildRenderTreeMeasured(
    allocator: std.mem.Allocator,
    widget: *const Widget,
    constraints: Constraints,
    backend: RenderBackend,
) !RenderNode {
    var element = try buildElementTree(allocator, widget, constraints);
    defer destroyElementTree(allocator, &element);
    return buildRenderTreeFromElement(allocator, &element, constraints, backend);
}

pub fn buildRenderTreeFromElement(
    allocator: std.mem.Allocator,
    element: *const Element,
    constraints: Constraints,
    backend: RenderBackend,
) !RenderNode {
    return layoutElement(allocator, element, constraints, .{ .x = 0, .y = 0 }, .{ .backend = backend });
}

pub fn buildElementTree(allocator: std.mem.Allocator, widget: *const Widget, constraints: Constraints) anyerror!Element {
    switch (widget.*) {
        .keyed => |keyed_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const element_key = try cloneKey(allocator, keyed_widget.key);
            errdefer destroyKey(allocator, element_key);
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTree(allocator, keyed_widget.child, constraints);
            initialized = true;
            return .{ .kind = .keyed, .widget = element_widget, .key = element_key, .children = children };
        },
        .text => return .{ .kind = .text, .widget = try cloneWidgetForElement(allocator, widget.*) },
        .text_input => return .{ .kind = .text_input, .widget = try cloneWidgetForElement(allocator, widget.*) },
        .render_object => return .{ .kind = .render_object, .widget = try cloneWidgetForElement(allocator, widget.*) },
        .box => |box_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTree(allocator, box_widget.child, constraints);
            initialized = true;
            return .{ .kind = .box, .widget = element_widget, .children = children };
        },
        .clickable => |clickable_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTree(allocator, clickable_widget.child, constraints);
            initialized = true;
            return .{ .kind = .clickable, .widget = element_widget, .children = children };
        },
        .padding => |padding_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTree(allocator, padding_widget.child, constraints.inset(padding_widget.insets));
            initialized = true;
            return .{ .kind = .padding, .widget = element_widget, .children = children };
        },
        .center => |center_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTree(allocator, center_widget.child, constraints);
            initialized = true;
            return .{ .kind = .center, .widget = element_widget, .children = children };
        },
        .row => |row_widget| return buildLinearElementTree(allocator, .row, widget.*, row_widget.children, constraints),
        .column => |column_widget| return buildLinearElementTree(allocator, .column, widget.*, column_widget.children, constraints),
        .component => |component_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const built = try component_widget.build(allocator, .{ .constraints = constraints });
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTree(allocator, &built, constraints);
            initialized = true;
            return .{ .kind = .component, .widget = element_widget, .children = children };
        },
        .stateful => |stateful_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const state = try stateful_widget.createState(allocator);
            errdefer stateful_widget.destroyState(state, allocator);
            const built = try stateful_widget.build(state, allocator, .{ .constraints = constraints });
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTree(allocator, &built, constraints);
            initialized = true;
            return .{ .kind = .stateful, .widget = element_widget, .state = state, .children = children };
        },
        .element => |custom_element| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try custom_element.build(allocator, .{ .constraints = constraints });
            initialized = true;
            return .{ .kind = .element, .widget = element_widget, .children = children };
        },
    }
}

fn buildLinearElementTree(
    allocator: std.mem.Allocator,
    kind: Element.Kind,
    widget: Widget,
    child_widgets: []const Widget,
    constraints: Constraints,
) anyerror!Element {
    std.debug.assert(kind == .row or kind == .column);

    var element_widget = try cloneWidgetForElement(allocator, widget);
    errdefer destroyElementWidget(allocator, &element_widget);
    const children = try allocator.alloc(Element, child_widgets.len);
    var initialized: usize = 0;
    errdefer {
        for (children[0..initialized]) |*child| destroyElementTree(allocator, child);
        allocator.free(children);
    }

    for (child_widgets, 0..) |*child_widget, index| {
        children[index] = try buildElementTree(allocator, child_widget, constraints);
        initialized += 1;
    }

    return .{ .kind = kind, .widget = element_widget, .children = children };
}

pub fn destroyElementTree(allocator: std.mem.Allocator, element: *Element) void {
    for (element.children) |*child| destroyElementTree(allocator, child);
    allocator.free(element.children);
    element.children = &.{};
    if (element.state) |state| {
        std.debug.assert(element.kind == .stateful);
        element.widget.stateful.destroyState(state, allocator);
        element.state = null;
    }
    if (element.key) |key| {
        destroyKey(allocator, key);
        element.key = null;
    }
    destroyElementWidget(allocator, &element.widget);
}

pub fn buildRenderObjectTree(allocator: std.mem.Allocator, element: *const Element) anyerror!RenderObjectNode {
    const children = try allocator.alloc(RenderObjectNode, element.children.len);
    var initialized: usize = 0;
    errdefer {
        for (children[0..initialized]) |*child| destroyRenderObjectTree(allocator, child);
        allocator.free(children);
    }

    for (element.children, 0..) |*element_child, index| {
        children[index] = try buildRenderObjectTree(allocator, element_child);
        initialized += 1;
    }

    return .{
        .kind = element.kind,
        .key = if (element.key) |key| try cloneKey(allocator, key) else null,
        .render_object = renderObjectForElement(element),
        .children = children,
    };
}

pub fn destroyRenderObjectTree(allocator: std.mem.Allocator, node: *RenderObjectNode) void {
    for (node.children) |*child| destroyRenderObjectTree(allocator, child);
    allocator.free(node.children);
    node.children = &.{};
    if (node.key) |key| {
        destroyKey(allocator, key);
        node.key = null;
    }
    node.render_object = null;
}

pub fn updateRenderObjectTree(allocator: std.mem.Allocator, node: *RenderObjectNode, element: *const Element) anyerror!void {
    if (!canUpdateRenderObjectNode(node, element)) {
        var replacement = try buildRenderObjectTree(allocator, element);
        errdefer destroyRenderObjectTree(allocator, &replacement);
        destroyRenderObjectTree(allocator, node);
        node.* = replacement;
        return;
    }

    if (element.key) |key| {
        if (node.key) |old_key| destroyKey(allocator, old_key);
        node.key = try cloneKey(allocator, key);
    } else if (node.key) |old_key| {
        destroyKey(allocator, old_key);
        node.key = null;
    }
    node.render_object = renderObjectForElement(element);

    if (hasKeyedRenderObjectChildren(node.children) or hasKeyedElements(element.children)) {
        try updateKeyedRenderObjectChildren(allocator, node, element.children);
    } else if (node.children.len == element.children.len) {
        for (element.children, 0..) |*element_child, index| {
            try updateRenderObjectTree(allocator, &node.children[index], element_child);
        }
    } else {
        const old_children = node.children;
        const new_children = try buildRenderObjectChildren(allocator, element.children);
        for (old_children) |*child| destroyRenderObjectTree(allocator, child);
        allocator.free(old_children);
        node.children = new_children;
    }
}

pub fn updateElementTree(allocator: std.mem.Allocator, element: *Element, widget: *const Widget, constraints: Constraints) anyerror!void {
    if (!canUpdateElement(element, widget)) {
        var replacement = try buildElementTree(allocator, widget, constraints);
        errdefer destroyElementTree(allocator, &replacement);
        destroyElementTree(allocator, element);
        element.* = replacement;
        return;
    }

    switch (widget.*) {
        .keyed => |keyed_widget| {
            try updateSingleChildElement(allocator, element, widget.*, keyed_widget.child, constraints);
            if (element.key) |old_key| destroyKey(allocator, old_key);
            element.key = try cloneKey(allocator, keyed_widget.key);
        },
        .text, .text_input, .render_object => try replaceElementWidget(allocator, element, widget.*),
        .box => |box_widget| {
            try updateSingleChildElement(allocator, element, widget.*, box_widget.child, constraints);
        },
        .clickable => |clickable_widget| {
            try updateSingleChildElement(allocator, element, widget.*, clickable_widget.child, constraints);
        },
        .padding => |padding_widget| {
            try updateSingleChildElement(allocator, element, widget.*, padding_widget.child, constraints.inset(padding_widget.insets));
        },
        .center => |center_widget| {
            try updateSingleChildElement(allocator, element, widget.*, center_widget.child, constraints);
        },
        .row => |row_widget| try updateLinearElement(allocator, element, widget.*, row_widget.children, constraints),
        .column => |column_widget| try updateLinearElement(allocator, element, widget.*, column_widget.children, constraints),
        .component => |component_widget| {
            const built = try component_widget.build(allocator, .{ .constraints = constraints });
            try updateSingleChildElement(allocator, element, widget.*, &built, constraints);
        },
        .stateful => |stateful_widget| {
            const state = element.state orelse return error.MissingState;
            try stateful_widget.update(state, allocator, .{ .constraints = constraints });
            const built = try stateful_widget.build(state, allocator, .{ .constraints = constraints });
            try updateSingleChildElement(allocator, element, widget.*, &built, constraints);
        },
        .element => |custom_element| {
            var replacement_child = try custom_element.build(allocator, .{ .constraints = constraints });
            errdefer destroyElementTree(allocator, &replacement_child);
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            destroyElementTree(allocator, &element.children[0]);
            element.children[0] = replacement_child;
            destroyElementWidget(allocator, &element.widget);
            element.widget = element_widget;
        },
    }
}

fn canUpdateElement(element: *const Element, widget: *const Widget) bool {
    return element.kind == elementKindForWidget(widget.*);
}

fn elementKindForWidget(widget: Widget) Element.Kind {
    return switch (widget) {
        .keyed => .keyed,
        .text => .text,
        .box => .box,
        .clickable => .clickable,
        .text_input => .text_input,
        .row => .row,
        .column => .column,
        .padding => .padding,
        .center => .center,
        .component => .component,
        .stateful => .stateful,
        .element => .element,
        .render_object => .render_object,
    };
}

fn updateSingleChildElement(
    allocator: std.mem.Allocator,
    element: *Element,
    widget: Widget,
    child_widget: *const Widget,
    child_constraints: Constraints,
) anyerror!void {
    std.debug.assert(element.children.len == 1);
    var element_widget = try cloneWidgetForElement(allocator, widget);
    errdefer destroyElementWidget(allocator, &element_widget);
    try updateElementTree(allocator, &element.children[0], child_widget, child_constraints);
    destroyElementWidget(allocator, &element.widget);
    element.widget = element_widget;
}

fn updateLinearElement(
    allocator: std.mem.Allocator,
    element: *Element,
    widget: Widget,
    child_widgets: []const Widget,
    constraints: Constraints,
) anyerror!void {
    if (hasKeyedChildren(element.children) or hasKeyedWidgets(child_widgets)) {
        try updateKeyedLinearElement(allocator, element, widget, child_widgets, constraints);
        return;
    }

    if (element.children.len != child_widgets.len) {
        var replacement = try buildElementTree(allocator, &widget, constraints);
        errdefer destroyElementTree(allocator, &replacement);
        destroyElementTree(allocator, element);
        element.* = replacement;
        return;
    }

    var element_widget = try cloneWidgetForElement(allocator, widget);
    errdefer destroyElementWidget(allocator, &element_widget);
    for (child_widgets, 0..) |*child_widget, index| {
        try updateElementTree(allocator, &element.children[index], child_widget, constraints);
    }
    destroyElementWidget(allocator, &element.widget);
    element.widget = element_widget;
}

fn updateKeyedLinearElement(
    allocator: std.mem.Allocator,
    element: *Element,
    widget: Widget,
    child_widgets: []const Widget,
    constraints: Constraints,
) !void {
    var element_widget = try cloneWidgetForElement(allocator, widget);
    errdefer destroyElementWidget(allocator, &element_widget);

    const old_children = element.children;
    const used = try allocator.alloc(bool, old_children.len);
    defer allocator.free(used);
    @memset(used, false);

    const new_children = try allocator.alloc(Element, child_widgets.len);
    var initialized: usize = 0;
    errdefer {
        for (new_children[0..initialized]) |*child| destroyElementTree(allocator, child);
        allocator.free(new_children);
        for (old_children, 0..) |*old_child, index| {
            if (!used[index]) destroyElementTree(allocator, old_child);
        }
        allocator.free(old_children);
    }

    for (child_widgets, 0..) |*child_widget, index| {
        if (widgetKey(child_widget.*)) |key| {
            if (findElementByKey(old_children, used, key)) |old_index| {
                used[old_index] = true;
                new_children[index] = old_children[old_index];
                try updateElementTree(allocator, &new_children[index], child_widget, constraints);
                initialized += 1;
                continue;
            }
        } else if (index < old_children.len and !used[index] and old_children[index].key == null) {
            used[index] = true;
            new_children[index] = old_children[index];
            try updateElementTree(allocator, &new_children[index], child_widget, constraints);
            initialized += 1;
            continue;
        }

        new_children[index] = try buildElementTree(allocator, child_widget, constraints);
        initialized += 1;
    }

    for (old_children, 0..) |*old_child, index| {
        if (!used[index]) destroyElementTree(allocator, old_child);
    }
    allocator.free(old_children);
    destroyElementWidget(allocator, &element.widget);
    element.widget = element_widget;
    element.children = new_children;
}

fn hasKeyedChildren(children: []const Element) bool {
    for (children) |child| if (child.key != null) return true;
    return false;
}

fn hasKeyedRenderObjectChildren(children: []const RenderObjectNode) bool {
    for (children) |child| if (child.key != null) return true;
    return false;
}

fn hasKeyedElements(elements: []const Element) bool {
    for (elements) |element| if (element.key != null) return true;
    return false;
}

fn hasKeyedWidgets(items: []const Widget) bool {
    for (items) |widget| if (widgetKey(widget) != null) return true;
    return false;
}

fn buildRenderObjectChildren(allocator: std.mem.Allocator, elements: []const Element) ![]RenderObjectNode {
    const children = try allocator.alloc(RenderObjectNode, elements.len);
    var initialized: usize = 0;
    errdefer {
        for (children[0..initialized]) |*child| destroyRenderObjectTree(allocator, child);
        allocator.free(children);
    }
    for (elements, 0..) |*element, index| {
        children[index] = try buildRenderObjectTree(allocator, element);
        initialized += 1;
    }
    return children;
}

fn updateKeyedRenderObjectChildren(allocator: std.mem.Allocator, node: *RenderObjectNode, elements: []const Element) !void {
    const old_children = node.children;
    const used = try allocator.alloc(bool, old_children.len);
    defer allocator.free(used);
    @memset(used, false);

    const new_children = try allocator.alloc(RenderObjectNode, elements.len);
    var initialized: usize = 0;
    errdefer {
        for (new_children[0..initialized]) |*child| destroyRenderObjectTree(allocator, child);
        allocator.free(new_children);
        for (old_children, 0..) |*old_child, index| {
            if (!used[index]) destroyRenderObjectTree(allocator, old_child);
        }
        allocator.free(old_children);
    }

    for (elements, 0..) |*element, index| {
        if (element.key) |key| {
            if (findRenderObjectNodeByKey(old_children, used, key)) |old_index| {
                used[old_index] = true;
                new_children[index] = old_children[old_index];
                try updateRenderObjectTree(allocator, &new_children[index], element);
                initialized += 1;
                continue;
            }
        } else if (index < old_children.len and !used[index] and old_children[index].key == null) {
            used[index] = true;
            new_children[index] = old_children[index];
            try updateRenderObjectTree(allocator, &new_children[index], element);
            initialized += 1;
            continue;
        }

        new_children[index] = try buildRenderObjectTree(allocator, element);
        initialized += 1;
    }

    for (old_children, 0..) |*old_child, index| {
        if (!used[index]) destroyRenderObjectTree(allocator, old_child);
    }
    allocator.free(old_children);
    node.children = new_children;
}

fn findElementByKey(children: []const Element, used: []const bool, key: Widget.Key) ?usize {
    for (children, 0..) |child, index| {
        if (used[index]) continue;
        const child_key = child.key orelse continue;
        if (keysEqual(child_key, key)) return index;
    }
    return null;
}

fn findRenderObjectNodeByKey(children: []const RenderObjectNode, used: []const bool, key: Widget.Key) ?usize {
    for (children, 0..) |child, index| {
        if (used[index]) continue;
        const child_key = child.key orelse continue;
        if (keysEqual(child_key, key)) return index;
    }
    return null;
}

fn canUpdateRenderObjectNode(node: *const RenderObjectNode, element: *const Element) bool {
    if (node.kind != element.kind) return false;
    if (node.key) |node_key| {
        const element_key = element.key orelse return false;
        return keysEqual(node_key, element_key);
    }
    return element.key == null;
}

fn renderObjectForElement(element: *const Element) ?Widget.RenderObject {
    if (element.kind != .render_object) return null;
    return element.widget.render_object;
}

fn widgetKey(widget: Widget) ?Widget.Key {
    return switch (widget) {
        .keyed => |keyed_widget| keyed_widget.key,
        else => null,
    };
}

fn replaceElementWidget(allocator: std.mem.Allocator, element: *Element, widget: Widget) anyerror!void {
    var element_widget = try cloneWidgetForElement(allocator, widget);
    errdefer destroyElementWidget(allocator, &element_widget);
    destroyElementWidget(allocator, &element.widget);
    element.widget = element_widget;
}

fn cloneWidgetForElement(allocator: std.mem.Allocator, widget: Widget) !Widget {
    return switch (widget) {
        .keyed => |keyed_widget| .{ .keyed = .{
            .key = try cloneKey(allocator, keyed_widget.key),
            .child = keyed_widget.child,
        } },
        .text => |text_widget| .{ .text = .{
            .value = try allocator.dupe(u8, text_widget.value),
            .color = text_widget.color,
        } },
        .box => |box_widget| .{ .box = box_widget },
        .clickable => |clickable_widget| .{ .clickable = .{
            .id = try allocator.dupe(u8, clickable_widget.id),
            .child = clickable_widget.child,
            .on_click = clickable_widget.on_click,
        } },
        .text_input => |input_widget| blk: {
            const id = try allocator.dupe(u8, input_widget.id);
            errdefer allocator.free(id);
            const value = try allocator.dupe(u8, input_widget.value);
            errdefer allocator.free(value);
            const placeholder = try allocator.dupe(u8, input_widget.placeholder);
            break :blk .{ .text_input = .{
                .id = id,
                .value = value,
                .placeholder = placeholder,
                .focused = input_widget.focused,
            } };
        },
        .row => |row_widget| .{ .row = .{ .children = &.{}, .gap = row_widget.gap } },
        .column => |column_widget| .{ .column = .{ .children = &.{}, .gap = column_widget.gap } },
        .padding => |padding_widget| .{ .padding = padding_widget },
        .center => |center_widget| .{ .center = center_widget },
        .component => |component_widget| .{ .component = component_widget },
        .stateful => |stateful_widget| .{ .stateful = stateful_widget },
        .element => |custom_element| .{ .element = custom_element },
        .render_object => |render_object| .{ .render_object = render_object },
    };
}

fn destroyElementWidget(allocator: std.mem.Allocator, widget: *Widget) void {
    switch (widget.*) {
        .keyed => |keyed_widget| destroyKey(allocator, keyed_widget.key),
        .text => |text_widget| allocator.free(text_widget.value),
        .clickable => |clickable_widget| allocator.free(clickable_widget.id),
        .text_input => |input_widget| {
            allocator.free(input_widget.id);
            allocator.free(input_widget.value);
            allocator.free(input_widget.placeholder);
        },
        .box, .row, .column, .padding, .center, .component, .stateful, .element, .render_object => {},
    }
}

fn cloneKey(allocator: std.mem.Allocator, key: Widget.Key) !Widget.Key {
    return switch (key) {
        .string => |value| .{ .string = try allocator.dupe(u8, value) },
        .integer => |value| .{ .integer = value },
    };
}

fn destroyKey(allocator: std.mem.Allocator, key: Widget.Key) void {
    switch (key) {
        .string => |value| allocator.free(value),
        .integer => {},
    }
}

fn keysEqual(a: Widget.Key, b: Widget.Key) bool {
    return switch (a) {
        .string => |a_value| switch (b) {
            .string => |b_value| std.mem.eql(u8, a_value, b_value),
            .integer => false,
        },
        .integer => |a_value| switch (b) {
            .string => false,
            .integer => |b_value| a_value == b_value,
        },
    };
}

pub fn destroyRenderTree(allocator: std.mem.Allocator, node: *RenderNode) void {
    for (node.children) |*child| {
        destroyRenderTree(allocator, child);
    }
    allocator.free(node.children);
    node.children = &.{};
    if (node.text) |value| allocator.free(value);
    if (node.clickable_id) |id| allocator.free(id);
    if (node.text_input_id) |id| allocator.free(id);
    if (node.placeholder) |placeholder| allocator.free(placeholder);
}

pub fn paint(allocator: std.mem.Allocator, node: *const RenderNode, display_list: *DisplayList) !void {
    switch (node.kind) {
        .render_object => {
            const render_object = node.render_object orelse return error.MissingRenderObject;
            try render_object.paint(.{ .allocator = allocator, .rect = node.rect, .display_list = display_list });
        },
        .box => {
            if (node.background.a > 0) try display_list.fillRect(allocator, node.rect, node.background);
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
    return if (hitTestClick(node, point)) |hit| hit.id else null;
}

pub const ClickHit = struct {
    id: []const u8,
    callback: ?Widget.Callback = null,
};

pub fn hitTestClick(node: *const RenderNode, point: Point) ?ClickHit {
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (hitTestClick(&node.children[index], point)) |hit| return hit;
    }

    if (node.kind == .clickable and node.rect.contains(point)) {
        return .{ .id = node.clickable_id orelse return null, .callback = node.click_callback };
    }
    if (node.kind == .render_object) {
        if (node.render_object) |render_object| {
            if (render_object.hitTest(node.rect, point)) |id| return .{ .id = id };
        }
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

pub fn hitTestCursorShape(node: *const RenderNode, point: Point) CursorShape {
    if (hitTestTextInput(node, point) != null) return .text;
    if (hitTestClick(node, point) != null) return .pointer;
    return .default;
}

fn layoutElement(allocator: std.mem.Allocator, element: *const Element, constraints: Constraints, origin: Point, measurer: TextMeasurer) LayoutError!RenderNode {
    switch (element.widget) {
        .keyed => |keyed_widget| {
            _ = keyed_widget;
            var child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            errdefer destroyRenderTree(allocator, &child);

            const children = try allocator.alloc(RenderNode, 1);
            children[0] = child;
            return .{
                .kind = .keyed,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .children = children,
            };
        },
        .text => |text_widget| {
            const measured = try measurer.measureText(text_widget.value);
            const size_value = constraints.clamp(measured);
            return .{
                .kind = .text,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .text = try allocator.dupe(u8, text_widget.value),
                .foreground = text_widget.color,
            };
        },
        .box => |box_widget| {
            var child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            errdefer destroyRenderTree(allocator, &child);

            const children = try allocator.alloc(RenderNode, 1);
            children[0] = child;
            return .{
                .kind = .box,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .background = box_widget.background,
                .children = children,
            };
        },
        .clickable => |clickable_widget| {
            const id = try allocator.dupe(u8, clickable_widget.id);
            errdefer allocator.free(id);
            var child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            errdefer destroyRenderTree(allocator, &child);

            const children = try allocator.alloc(RenderNode, 1);
            children[0] = child;
            return .{
                .kind = .clickable,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .clickable_id = id,
                .click_callback = clickable_widget.on_click,
                .children = children,
            };
        },
        .text_input => |input_widget| {
            const value = try allocator.dupe(u8, input_widget.value);
            errdefer allocator.free(value);
            const id = try allocator.dupe(u8, input_widget.id);
            errdefer allocator.free(id);
            const placeholder = try allocator.dupe(u8, input_widget.placeholder);
            errdefer allocator.free(placeholder);
            const text_value = if (input_widget.value.len > 0) input_widget.value else input_widget.placeholder;
            const measured = try measurer.measureText(text_value);
            const value_size = try measurer.measureText(input_widget.value);
            const requested = Size{
                .width = @max(input_min_width, @max(measured.width + input_horizontal_padding * 2, constraints.max_width)),
                .height = measured.height + input_vertical_padding * 2,
            };
            const size_value = constraints.clamp(requested);
            return .{
                .kind = .text_input,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .text = value,
                .text_input_id = id,
                .foreground = colors.ink,
                .background = colors.white,
                .placeholder = placeholder,
                .focused = input_widget.focused,
                .caret_x = origin.x + input_horizontal_padding + value_size.width,
            };
        },
        .padding => |padding_widget| {
            var child = try layoutElement(allocator, &element.children[0], constraints.inset(padding_widget.insets), .{
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
            _ = center_widget;
            var child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
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
        .column => |column_widget| return layoutLinearElements(allocator, .column, element.children, column_widget.gap, constraints, origin, measurer),
        .row => |row_widget| return layoutLinearElements(allocator, .row, element.children, row_widget.gap, constraints, origin, measurer),
        .component => |component_widget| {
            _ = component_widget;
            var child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            errdefer destroyRenderTree(allocator, &child);

            const children = try allocator.alloc(RenderNode, 1);
            children[0] = child;
            return .{
                .kind = .component,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .children = children,
            };
        },
        .stateful => |stateful_widget| {
            _ = stateful_widget;
            var child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            errdefer destroyRenderTree(allocator, &child);

            const children = try allocator.alloc(RenderNode, 1);
            children[0] = child;
            return .{
                .kind = .stateful,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .children = children,
            };
        },
        .element => |custom_element| {
            _ = custom_element;
            var child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            errdefer destroyRenderTree(allocator, &child);

            const children = try allocator.alloc(RenderNode, 1);
            children[0] = child;
            return .{
                .kind = .element,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .children = children,
            };
        },
        .render_object => |render_widget| {
            const measured = try render_widget.layout(.{ .constraints = constraints, .measurer = measurer });
            const size_value = constraints.clamp(measured);
            return .{
                .kind = .render_object,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .render_object = render_widget,
            };
        },
    }
}

fn layoutLinearElements(
    allocator: std.mem.Allocator,
    comptime kind: RenderNode.Kind,
    elements: []const Element,
    gap: f32,
    constraints: Constraints,
    origin: Point,
    measurer: TextMeasurer,
) LayoutError!RenderNode {
    std.debug.assert(kind == .row or kind == .column);

    const children = try allocator.alloc(RenderNode, elements.len);
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
    for (elements, 0..) |*child_element, index| {
        const remaining = switch (kind) {
            .row => Constraints{ .max_width = @max(0, constraints.max_width - (cursor.x - origin.x)), .max_height = constraints.max_height },
            .column => Constraints{ .max_width = constraints.max_width, .max_height = @max(0, constraints.max_height - (cursor.y - origin.y)) },
            else => unreachable,
        };
        children[index] = try layoutElement(allocator, child_element, remaining, cursor, measurer);
        initialized += 1;

        switch (kind) {
            .row => {
                cursor.x += children[index].rect.width + gap;
                width += children[index].rect.width;
                if (index + 1 < elements.len) width += gap;
                height = @max(height, children[index].rect.height);
            },
            .column => {
                cursor.y += children[index].rect.height + gap;
                height += children[index].rect.height;
                if (index + 1 < elements.len) height += gap;
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

test "layout, paint, and hit test a padded column" {
    const allocator = std.testing.allocator;

    const title: Widget = .{ .text = .{ .value = "Title" } };
    const label: Widget = .{ .text = .{ .value = "OK", .color = colors.white } };
    const button_padding: Widget = .{ .padding = .{ .insets = EdgeInsets.all(8), .child = &label } };
    const button_box: Widget = .{ .box = .{ .background = colors.accent, .child = &button_padding } };
    const button: Widget = .{ .clickable = .{ .id = "ok", .child = &button_box } };
    const children = [_]Widget{ title, button };
    const column: Widget = .{ .column = .{ .children = &children, .gap = 4 } };
    const padded: Widget = .{ .padding = .{ .insets = EdgeInsets.all(10), .child = &column } };

    var root = try buildRenderTree(allocator, &padded, .{ .max_width = 200, .max_height = 120 });
    defer destroyRenderTree(allocator, &root);

    try std.testing.expectEqual(@as(RenderNode.Kind, .padding), root.kind);
    try std.testing.expectEqual(@as(f32, 60), root.rect.width);
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

    const label: Widget = .{ .text = .{ .value = "Run" } };
    const button: Widget = .{ .clickable = .{ .id = "centered", .child = &label } };
    const center: Widget = .{ .center = .{ .child = &button } };

    var root = try buildRenderTree(allocator, &center, .{ .max_width = 100, .max_height = 80 });
    defer destroyRenderTree(allocator, &root);

    try std.testing.expectEqual(@as(f32, 38), root.children[0].rect.x);
    try std.testing.expectEqual(@as(f32, 32), root.children[0].rect.y);
    try std.testing.expectEqualStrings("centered", hitTestButton(&root, .{ .x = 40, .y = 35 }).?);
}

test "clickable carries opaque callback handles through hit testing" {
    const Counter = struct {
        value: usize = 0,

        fn increment(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.value += 1;
        }
    };

    var counter: Counter = .{};
    const label: Widget = .{ .text = .{ .value = "Count" } };
    const button: Widget = .{ .clickable = .{
        .id = "counter",
        .child = &label,
        .on_click = .{ .ptr = &counter, .call_fn = Counter.increment },
    } };

    var root = try buildRenderTree(std.testing.allocator, &button, .{ .max_width = 100, .max_height = 80 });
    defer destroyRenderTree(std.testing.allocator, &root);

    const hit = hitTestClick(&root, .{ .x = 2, .y = 2 }).?;
    try std.testing.expectEqualStrings("counter", hit.id);
    try hit.callback.?.call();
    try std.testing.expectEqual(@as(usize, 1), counter.value);
}

test "component widget builds into the render tree" {
    const LabelComponent = struct {
        value: []const u8,

        const vtable: Widget.Component.VTable = .{ .build = build };

        fn widget(self: *const @This()) Widget {
            return .{ .component = .{ .ptr = self, .vtable = &vtable } };
        }

        fn build(ptr: *const anyopaque, allocator: std.mem.Allocator, context: Widget.BuildContext) !Widget {
            _ = allocator;
            _ = context;
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            return .{ .text = .{ .value = self.value } };
        }
    };

    const component: LabelComponent = .{ .value = "Component" };
    const widget = component.widget();

    var root = try buildRenderTree(std.testing.allocator, &widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyRenderTree(std.testing.allocator, &root);

    try std.testing.expectEqual(@as(RenderNode.Kind, .component), root.kind);
    try std.testing.expectEqual(@as(RenderNode.Kind, .text), root.children[0].kind);
    try std.testing.expectEqualStrings("Component", root.children[0].text.?);
}

test "stateful widget creates state once across matching updates" {
    const StatefulCounter = struct {
        label: []const u8,
        created: *usize,
        updated: *usize,
        destroyed: *usize,

        const State = struct {
            builds: usize = 0,
        };

        const vtable: Widget.Stateful.VTable = .{
            .create_state = createState,
            .update = update,
            .build = build,
            .destroy_state = destroyState,
        };

        fn widget(self: *const @This()) Widget {
            return .{ .stateful = .{ .ptr = self, .vtable = &vtable } };
        }

        fn createState(ptr: *const anyopaque, allocator: std.mem.Allocator) !*anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.created.* += 1;
            const state = try allocator.create(State);
            state.* = .{};
            return state;
        }

        fn update(ptr: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator, context: Widget.BuildContext) !void {
            _ = state_ptr;
            _ = allocator;
            _ = context;
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.updated.* += 1;
        }

        fn build(ptr: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator, context: Widget.BuildContext) !Widget {
            _ = allocator;
            _ = context;
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            const state: *State = @ptrCast(@alignCast(state_ptr));
            state.builds += 1;
            return .{ .text = .{ .value = self.label } };
        }

        fn destroyState(ptr: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.destroyed.* += 1;
            const state: *State = @ptrCast(@alignCast(state_ptr));
            allocator.destroy(state);
        }
    };

    var created: usize = 0;
    var updated: usize = 0;
    var destroyed: usize = 0;
    const first: StatefulCounter = .{ .label = "first", .created = &created, .updated = &updated, .destroyed = &destroyed };
    const first_widget = first.widget();
    var element = try buildElementTree(std.testing.allocator, &first_widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &element);

    const original_state = element.state.?;
    try std.testing.expectEqual(@as(usize, 1), created);
    try std.testing.expectEqual(@as(usize, 0), updated);
    try std.testing.expectEqualStrings("first", element.children[0].widget.text.value);

    const second: StatefulCounter = .{ .label = "second", .created = &created, .updated = &updated, .destroyed = &destroyed };
    const second_widget = second.widget();
    try updateElementTree(std.testing.allocator, &element, &second_widget, .{ .max_width = 200, .max_height = 80 });

    try std.testing.expectEqual(original_state, element.state.?);
    try std.testing.expectEqual(@as(usize, 1), created);
    try std.testing.expectEqual(@as(usize, 1), updated);
    try std.testing.expectEqual(@as(usize, 0), destroyed);
    try std.testing.expectEqualStrings("second", element.children[0].widget.text.value);
}

test "stateful widget destroys state on element destruction and replacement" {
    const Lifecycle = struct {
        created: *usize,
        destroyed: *usize,

        const State = struct {};
        const vtable: Widget.Stateful.VTable = .{
            .create_state = createState,
            .update = update,
            .build = build,
            .destroy_state = destroyState,
        };

        fn widget(self: *const @This()) Widget {
            return .{ .stateful = .{ .ptr = self, .vtable = &vtable } };
        }

        fn createState(ptr: *const anyopaque, allocator: std.mem.Allocator) !*anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.created.* += 1;
            const state = try allocator.create(State);
            state.* = .{};
            return state;
        }

        fn update(ptr: *const anyopaque, state: *anyopaque, allocator: std.mem.Allocator, context: Widget.BuildContext) !void {
            _ = ptr;
            _ = state;
            _ = allocator;
            _ = context;
        }

        fn build(ptr: *const anyopaque, state: *anyopaque, allocator: std.mem.Allocator, context: Widget.BuildContext) !Widget {
            _ = ptr;
            _ = state;
            _ = allocator;
            _ = context;
            return .{ .text = .{ .value = "stateful" } };
        }

        fn destroyState(ptr: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.destroyed.* += 1;
            const state: *State = @ptrCast(@alignCast(state_ptr));
            allocator.destroy(state);
        }
    };

    var created: usize = 0;
    var destroyed: usize = 0;
    const lifecycle: Lifecycle = .{ .created = &created, .destroyed = &destroyed };
    const widget = lifecycle.widget();
    var element = try buildElementTree(std.testing.allocator, &widget, .{ .max_width = 200, .max_height = 80 });
    try std.testing.expectEqual(@as(usize, 1), created);

    const replacement: Widget = .{ .text = .{ .value = "replacement" } };
    try updateElementTree(std.testing.allocator, &element, &replacement, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &element);
    try std.testing.expectEqual(@as(usize, 1), destroyed);
    try std.testing.expectEqual(@as(Element.Kind, .text), element.kind);

    var destroyed_on_deinit: usize = 0;
    const second_lifecycle: Lifecycle = .{ .created = &created, .destroyed = &destroyed_on_deinit };
    const second_widget = second_lifecycle.widget();
    var second_element = try buildElementTree(std.testing.allocator, &second_widget, .{ .max_width = 200, .max_height = 80 });
    destroyElementTree(std.testing.allocator, &second_element);
    try std.testing.expectEqual(@as(usize, 1), destroyed_on_deinit);
}

test "custom element widget builds an element subtree" {
    const LabelElement = struct {
        value: []const u8,

        const vtable: Widget.CustomElement.VTable = .{ .build = build };

        fn widget(self: *const @This()) Widget {
            return .{ .element = .{ .ptr = self, .vtable = &vtable } };
        }

        fn build(ptr: *const anyopaque, allocator: std.mem.Allocator, context: Widget.BuildContext) !Element {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            const label: Widget = .{ .text = .{ .value = self.value, .color = colors.accent } };
            return buildElementTree(allocator, &label, context.constraints);
        }
    };

    const custom: LabelElement = .{ .value = "Element" };
    const widget = custom.widget();

    var element = try buildElementTree(std.testing.allocator, &widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(std.testing.allocator, &element);

    try std.testing.expectEqual(@as(Element.Kind, .element), element.kind);
    try std.testing.expectEqual(@as(Element.Kind, .text), element.children[0].kind);

    var root = try layoutElement(std.testing.allocator, &element, .{ .max_width = 200, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);
    defer destroyRenderTree(std.testing.allocator, &root);

    try std.testing.expectEqual(@as(RenderNode.Kind, .element), root.kind);
    try std.testing.expectEqual(@as(RenderNode.Kind, .text), root.children[0].kind);
    try std.testing.expectEqualStrings("Element", root.children[0].text.?);
    try std.testing.expectEqual(colors.accent, root.children[0].foreground);
}

test "element update reuses matching children and replaces shape changes" {
    const allocator = std.testing.allocator;

    const first_children = [_]Widget{
        .{ .text = .{ .value = "A" } },
        .{ .text = .{ .value = "B" } },
    };
    const first: Widget = .{ .column = .{ .children = &first_children, .gap = 2 } };
    var element = try buildElementTree(allocator, &first, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(allocator, &element);

    const original_children = element.children.ptr;
    const second_children = [_]Widget{
        .{ .text = .{ .value = "C" } },
        .{ .text = .{ .value = "D" } },
    };
    const second: Widget = .{ .column = .{ .children = &second_children, .gap = 6 } };
    try updateElementTree(allocator, &element, &second, .{ .max_width = 200, .max_height = 80 });

    try std.testing.expectEqual(original_children, element.children.ptr);
    try std.testing.expectEqual(@as(usize, 2), element.children.len);
    try std.testing.expectEqual(@as(f32, 6), element.widget.column.gap);
    try std.testing.expectEqualStrings("C", element.children[0].widget.text.value);
    try std.testing.expectEqualStrings("D", element.children[1].widget.text.value);

    const third_children = [_]Widget{
        .{ .text = .{ .value = "E" } },
    };
    const third: Widget = .{ .column = .{ .children = &third_children, .gap = 1 } };
    try updateElementTree(allocator, &element, &third, .{ .max_width = 200, .max_height = 80 });

    try std.testing.expectEqual(@as(usize, 1), element.children.len);
    try std.testing.expectEqual(@as(f32, 1), element.widget.column.gap);
    try std.testing.expectEqualStrings("E", element.children[0].widget.text.value);
}

test "keyed linear update matches children by key" {
    const allocator = std.testing.allocator;

    const a_text: Widget = .{ .text = .{ .value = "A" } };
    const b_text: Widget = .{ .text = .{ .value = "B" } };
    const first_children = [_]Widget{
        .{ .keyed = .{ .key = .{ .string = "a" }, .child = &a_text } },
        .{ .keyed = .{ .key = .{ .string = "b" }, .child = &b_text } },
    };
    const first: Widget = .{ .column = .{ .children = &first_children } };
    var element = try buildElementTree(allocator, &first, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(allocator, &element);

    const old_b_child = element.children[1].children.ptr;

    const b2_text: Widget = .{ .text = .{ .value = "B2" } };
    const c_text: Widget = .{ .text = .{ .value = "C" } };
    const a2_text: Widget = .{ .text = .{ .value = "A2" } };
    const second_children = [_]Widget{
        .{ .keyed = .{ .key = .{ .string = "b" }, .child = &b2_text } },
        .{ .keyed = .{ .key = .{ .string = "c" }, .child = &c_text } },
        .{ .keyed = .{ .key = .{ .string = "a" }, .child = &a2_text } },
    };
    const second: Widget = .{ .column = .{ .children = &second_children } };
    try updateElementTree(allocator, &element, &second, .{ .max_width = 200, .max_height = 80 });

    try std.testing.expectEqual(@as(usize, 3), element.children.len);
    try std.testing.expectEqual(old_b_child, element.children[0].children.ptr);
    try std.testing.expectEqualStrings("b", element.children[0].key.?.string);
    try std.testing.expectEqualStrings("B2", element.children[0].children[0].widget.text.value);
    try std.testing.expectEqualStrings("c", element.children[1].key.?.string);
    try std.testing.expectEqualStrings("C", element.children[1].children[0].widget.text.value);
    try std.testing.expectEqualStrings("a", element.children[2].key.?.string);
    try std.testing.expectEqualStrings("A2", element.children[2].children[0].widget.text.value);
}

test "render object tree update reuses keyed render object nodes across reorder" {
    const TestRenderObject = struct {
        id: u8,

        const vtable: Widget.RenderObject.VTable = .{ .layout = layout, .paint = paintObject };

        fn widget(self: *const @This()) Widget {
            return .{ .render_object = .{ .ptr = self, .vtable = &vtable } };
        }

        fn layout(ptr: *const anyopaque, context: Widget.RenderObject.LayoutContext) !Size {
            _ = ptr;
            _ = context;
            return .{ .width = 1, .height = 1 };
        }

        fn paintObject(ptr: *const anyopaque, context: Widget.RenderObject.PaintContext) !void {
            _ = ptr;
            _ = context;
        }
    };

    const allocator = std.testing.allocator;
    const a: TestRenderObject = .{ .id = 'a' };
    const b: TestRenderObject = .{ .id = 'b' };
    const a_widget = a.widget();
    const b_widget = b.widget();
    const first_children = [_]Widget{
        .{ .keyed = .{ .key = .{ .string = "a" }, .child = &a_widget } },
        .{ .keyed = .{ .key = .{ .string = "b" }, .child = &b_widget } },
    };
    const first: Widget = .{ .column = .{ .children = &first_children } };
    var element = try buildElementTree(allocator, &first, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(allocator, &element);

    var render_objects = try buildRenderObjectTree(allocator, &element);
    defer destroyRenderObjectTree(allocator, &render_objects);

    const old_b_child_nodes = render_objects.children[1].children.ptr;
    try std.testing.expectEqual(@as(?*const anyopaque, &b), render_objects.children[1].children[0].render_object.?.ptr);

    const second_children = [_]Widget{
        .{ .keyed = .{ .key = .{ .string = "b" }, .child = &b_widget } },
        .{ .keyed = .{ .key = .{ .string = "a" }, .child = &a_widget } },
    };
    const second: Widget = .{ .column = .{ .children = &second_children } };
    try updateElementTree(allocator, &element, &second, .{ .max_width = 200, .max_height = 80 });
    try updateRenderObjectTree(allocator, &render_objects, &element);

    try std.testing.expectEqual(old_b_child_nodes, render_objects.children[0].children.ptr);
    try std.testing.expectEqualStrings("b", render_objects.children[0].key.?.string);
    try std.testing.expectEqual(@as(?*const anyopaque, &b), render_objects.children[0].children[0].render_object.?.ptr);
}

test "render object widget owns custom layout paint and hit testing" {
    const BadgeRenderObject = struct {
        id: []const u8,

        const vtable: Widget.RenderObject.VTable = .{
            .layout = layoutBadge,
            .paint = paintBadge,
            .hit_test = hitTest,
        };

        fn widget(self: *const @This()) Widget {
            return .{ .render_object = .{ .ptr = self, .vtable = &vtable } };
        }

        fn layoutBadge(ptr: *const anyopaque, context: Widget.RenderObject.LayoutContext) !Size {
            _ = ptr;
            _ = context.measurer;
            return context.constraints.clamp(.{ .width = 48, .height = 20 });
        }

        fn paintBadge(ptr: *const anyopaque, context: Widget.RenderObject.PaintContext) !void {
            _ = ptr;
            try context.display_list.fillRect(context.allocator, context.rect, colors.accent);
        }

        fn hitTest(ptr: *const anyopaque, rect: Rect, point: Point) ?[]const u8 {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            return if (rect.contains(point)) self.id else null;
        }
    };

    const badge: BadgeRenderObject = .{ .id = "badge" };
    const widget = badge.widget();

    var root = try buildRenderTree(std.testing.allocator, &widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyRenderTree(std.testing.allocator, &root);

    try std.testing.expectEqual(@as(RenderNode.Kind, .render_object), root.kind);
    try std.testing.expectEqual(@as(f32, 48), root.rect.width);
    try std.testing.expectEqual(@as(f32, 20), root.rect.height);

    var display_list: DisplayList = .{};
    defer display_list.deinit(std.testing.allocator);
    try paint(std.testing.allocator, &root, &display_list);

    try std.testing.expectEqual(@as(usize, 1), display_list.commands.items.len);
    try std.testing.expectEqualStrings("badge", hitTestButton(&root, .{ .x = 8, .y = 8 }).?);
    try std.testing.expect(hitTestButton(&root, .{ .x = 80, .y = 8 }) == null);
}
