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

pub const Brightness = enum {
    light,
    dark,
};

pub const ColorScheme = struct {
    brightness: Brightness,
    primary: Color,
    on_primary: Color,
    surface: Color,
    on_surface: Color,
    surface_variant: Color,
    on_surface_variant: Color,
    outline: Color,
    error_color: Color,
    on_error: Color,

    pub const light: ColorScheme = .{
        .brightness = .light,
        .primary = colors.accent,
        .on_primary = colors.white,
        .surface = colors.panel,
        .on_surface = colors.ink,
        .surface_variant = colors.white,
        .on_surface_variant = colors.ink,
        .outline = colors.ink,
        .error_color = Color.argb(0xff, 0xba, 0x1a, 0x1a),
        .on_error = colors.white,
    };

    pub const dark: ColorScheme = .{
        .brightness = .dark,
        .primary = Color.argb(0xff, 0x9b, 0x86, 0xff),
        .on_primary = colors.black,
        .surface = Color.argb(0xff, 0x20, 0x20, 0x24),
        .on_surface = colors.white,
        .surface_variant = Color.argb(0xff, 0x2b, 0x2b, 0x30),
        .on_surface_variant = colors.white,
        .outline = Color.argb(0xff, 0x9b, 0x86, 0xff),
        .error_color = Color.argb(0xff, 0xff, 0xb4, 0xab),
        .on_error = Color.argb(0xff, 0x69, 0x00, 0x05),
    };
};

pub const TextStyle = struct {
    color: ?Color = null,
};

pub const TextTheme = struct {
    body: TextStyle = .{},
    label: TextStyle = .{},
};

pub const ButtonTheme = struct {
    background: ?Color = null,
    foreground: ?Color = null,
    hover_background: ?Color = null,
    hover_foreground: ?Color = null,
    focused_border: ?Color = null,
    pressed_background: ?Color = null,
    disabled_background: ?Color = null,
    disabled_foreground: ?Color = null,
    padding: f32 = 8,
};

pub const InputTheme = struct {
    background: ?Color = null,
    foreground: ?Color = null,
    placeholder: ?Color = null,
    border: ?Color = null,
    focused_border: ?Color = null,
};

pub const Theme = struct {
    color_scheme: ColorScheme,
    text_theme: TextTheme = .{},
    button_theme: ButtonTheme = .{},
    input_theme: InputTheme = .{},

    pub const light: Theme = .{
        .color_scheme = .light,
        .button_theme = .{ .pressed_background = colors.ink },
        .input_theme = .{ .placeholder = Color.argb(0xff, 0x77, 0x77, 0x7d) },
    };
    pub const dark: Theme = .{
        .color_scheme = .dark,
        .button_theme = .{ .pressed_background = Color.argb(0xff, 0xcc, 0xc2, 0xff) },
        .input_theme = .{ .placeholder = Color.argb(0xff, 0xb7, 0xb3, 0xc1) },
    };
    pub const default: Theme = light;

    pub fn fromColorScheme(scheme: []const u8) Theme {
        if (std.mem.eql(u8, scheme, "dark")) return .dark;
        return .light;
    }
};

pub const InteractionState = struct {
    hovered_id: ?[]const u8 = null,
    pressed_id: ?[]const u8 = null,
    focused_id: ?[]const u8 = null,

    pub fn isHovered(self: InteractionState, id: []const u8) bool {
        const hovered = self.hovered_id orelse return false;
        return std.mem.eql(u8, hovered, id);
    }

    pub fn isPressed(self: InteractionState, id: []const u8) bool {
        const pressed = self.pressed_id orelse return false;
        return std.mem.eql(u8, pressed, id);
    }

    pub fn isFocused(self: InteractionState, node: FocusNode) bool {
        const focused = self.focused_id orelse return false;
        return std.mem.eql(u8, focused, node.id);
    }
};

pub const PointerButtonState = enum {
    pressed,
    released,
};

pub const LayerShellOptions = struct {
    namespace: [:0]const u8 = "keywork",
    layer: Layer = .top,
    anchors: AnchorSet = .{},
    exclusive_zone: i32 = 0,
    margin: Margin = .{},
    keyboard_interactivity: KeyboardInteractivity = .none,

    pub const Layer = enum {
        background,
        bottom,
        top,
        overlay,
    };

    pub const AnchorSet = packed struct {
        top: bool = false,
        bottom: bool = false,
        left: bool = false,
        right: bool = false,
    };

    pub const Margin = struct {
        top: i32 = 0,
        right: i32 = 0,
        bottom: i32 = 0,
        left: i32 = 0,
    };

    pub const KeyboardInteractivity = enum {
        none,
        exclusive,
        on_demand,
    };
};

pub const ShortcutKey = enum {
    enter,
    space,
    backspace,
};

pub const Intent = struct {
    action_id: []const u8,

    pub fn action(action_id: []const u8) Intent {
        return .{ .action_id = action_id };
    }
};

pub const FocusNode = struct {
    id: []const u8,

    pub fn named(id: []const u8) FocusNode {
        return .{ .id = id };
    }
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
    focus: Focus,
    focus_scope: FocusScope,
    text_input: TextInput,
    row: Children,
    column: Children,
    spacer: Spacer,
    padding: Padding,
    center: Child,
    button: Button,
    actions: Actions,
    shortcuts: Shortcuts,
    theme: ThemeWidget,
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
        color: ?Color = null,
    };

    pub const Button = struct {
        id: []const u8,
        label: []const u8,
        on_pressed: ?Callback = null,
        intent: ?Intent = null,
    };

    pub const Box = struct {
        child: *const Widget,
        background: Color = colors.transparent,
        border: ?Color = null,
    };

    pub const Clickable = struct {
        id: []const u8,
        child: *const Widget,
        on_click: ?Callback = null,
        on_tap_down: ?Callback = null,
        on_tap_up: ?Callback = null,
        on_tap_cancel: ?Callback = null,
        activation: ClickActivation = .release,
    };

    pub const ClickActivation = enum {
        release,
        press,
    };

    pub const Focus = struct {
        node: FocusNode,
        child: *const Widget,
        autofocus: bool = false,
        skip_traversal: bool = false,
        can_request_focus: bool = true,
        on_focus_change: ?FocusChangeCallback = null,
    };

    pub const FocusScope = struct {
        id: []const u8,
        child: *const Widget,
        modal: bool = false,
    };

    pub const ActionBinding = struct {
        id: []const u8,
        callback: Callback,
    };

    pub const ShortcutBinding = struct {
        key: ShortcutKey,
        intent: Intent,
    };

    pub const Actions = struct {
        bindings: []const ActionBinding,
        child: *const Widget,
    };

    pub const Shortcuts = struct {
        bindings: []const ShortcutBinding,
        child: *const Widget,
    };

    pub const TextInput = struct {
        id: []const u8,
        focus_node: FocusNode,
        value: []const u8,
        placeholder: []const u8,
        foreground: Color = colors.ink,
        background: Color = colors.white,
        border: Color = colors.ink,
        focused_border: Color = colors.accent,
        placeholder_foreground: Color = Color.argb(0xff, 0x77, 0x77, 0x7d),
    };

    pub const Children = struct {
        children: []const Widget,
        gap: f32 = 0,
    };

    pub const Spacer = struct {
        flex: f32 = 1,
    };

    pub const Padding = struct {
        insets: EdgeInsets,
        child: *const Widget,
    };

    pub const Child = struct {
        child: *const Widget,
    };

    pub const ThemeWidget = struct {
        theme: Theme,
        child: *const Widget,
    };

    pub const Callback = struct {
        ptr: *anyopaque,
        call_fn: *const fn (ptr: *anyopaque) anyerror!void,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) anyerror!*anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void = null,

        pub fn call(self: Callback) !void {
            try self.call_fn(self.ptr);
        }

        pub fn clone(self: Callback, allocator: std.mem.Allocator) !Callback {
            const clone_fn = self.clone_fn orelse return self;
            return .{
                .ptr = try clone_fn(allocator, self.ptr),
                .call_fn = self.call_fn,
                .clone_fn = self.clone_fn,
                .destroy_fn = self.destroy_fn,
            };
        }

        pub fn destroy(self: Callback, allocator: std.mem.Allocator) void {
            const destroy_fn = self.destroy_fn orelse return;
            destroy_fn(allocator, self.ptr);
        }
    };

    pub const FocusChangeCallback = struct {
        ptr: *anyopaque,
        call_fn: *const fn (ptr: *anyopaque, focused: bool) anyerror!void,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) anyerror!*anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void = null,

        pub fn call(self: FocusChangeCallback, focused: bool) !void {
            try self.call_fn(self.ptr, focused);
        }

        pub fn clone(self: FocusChangeCallback, allocator: std.mem.Allocator) !FocusChangeCallback {
            const clone_fn = self.clone_fn orelse return self;
            return .{
                .ptr = try clone_fn(allocator, self.ptr),
                .call_fn = self.call_fn,
                .clone_fn = self.clone_fn,
                .destroy_fn = self.destroy_fn,
            };
        }

        pub fn destroy(self: FocusChangeCallback, allocator: std.mem.Allocator) void {
            const destroy_fn = self.destroy_fn orelse return;
            destroy_fn(allocator, self.ptr);
        }
    };

    pub const BuildContext = struct {
        constraints: Constraints,
        theme: Theme = .default,
        interaction: InteractionState = .{},
        app_context: AppContext = .{},
    };

    pub const Component = struct {
        ptr: *const anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            build: *const fn (ptr: *const anyopaque, scope: *BuildScope, context: BuildContext) anyerror!Widget,
        };

        pub fn build(self: Component, scope: *BuildScope, context: BuildContext) !Widget {
            return self.vtable.build(self.ptr, scope, context);
        }
    };

    pub const Stateful = struct {
        ptr: *const anyopaque,
        vtable: *const VTable,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) anyerror!*const anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) void = null,

        pub const VTable = struct {
            create_state: *const fn (ptr: *const anyopaque, allocator: std.mem.Allocator) anyerror!*anyopaque,
            update: *const fn (ptr: *const anyopaque, state: *anyopaque, allocator: std.mem.Allocator, context: BuildContext) anyerror!void,
            build: *const fn (ptr: *const anyopaque, state: *anyopaque, scope: *BuildScope, context: BuildContext) anyerror!Widget,
            destroy_state: *const fn (ptr: *const anyopaque, state: *anyopaque, allocator: std.mem.Allocator) void,
            needs_rebuild: ?*const fn (ptr: *const anyopaque, state: *anyopaque) bool = null,
            clear_rebuild: ?*const fn (ptr: *const anyopaque, state: *anyopaque) void = null,
        };

        pub fn createState(self: Stateful, allocator: std.mem.Allocator) !*anyopaque {
            return self.vtable.create_state(self.ptr, allocator);
        }

        pub fn update(self: Stateful, state: *anyopaque, allocator: std.mem.Allocator, context: BuildContext) !void {
            try self.vtable.update(self.ptr, state, allocator, context);
        }

        pub fn build(self: Stateful, state: *anyopaque, scope: *BuildScope, context: BuildContext) !Widget {
            return self.vtable.build(self.ptr, state, scope, context);
        }

        pub fn destroyState(self: Stateful, state: *anyopaque, allocator: std.mem.Allocator) void {
            self.vtable.destroy_state(self.ptr, state, allocator);
        }

        pub fn needsRebuild(self: Stateful, state: *anyopaque) bool {
            const needs_rebuild = self.vtable.needs_rebuild orelse return false;
            return needs_rebuild(self.ptr, state);
        }

        pub fn clearRebuild(self: Stateful, state: *anyopaque) void {
            const clear_rebuild = self.vtable.clear_rebuild orelse return;
            clear_rebuild(self.ptr, state);
        }

        pub fn clone(self: Stateful, allocator: std.mem.Allocator) !Stateful {
            const clone_fn = self.clone_fn orelse return self;
            return .{
                .ptr = try clone_fn(allocator, self.ptr),
                .vtable = self.vtable,
                .clone_fn = self.clone_fn,
                .destroy_fn = self.destroy_fn,
            };
        }

        pub fn destroy(self: Stateful, allocator: std.mem.Allocator) void {
            const destroy_fn = self.destroy_fn orelse return;
            destroy_fn(allocator, self.ptr);
        }
    };

    pub const CustomElement = struct {
        ptr: *const anyopaque,
        vtable: *const VTable,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) anyerror!*const anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) void = null,

        pub const VTable = struct {
            build: *const fn (ptr: *const anyopaque, allocator: std.mem.Allocator, scope: *BuildScope, context: BuildContext) anyerror!Element,
        };

        pub fn build(self: CustomElement, allocator: std.mem.Allocator, scope: *BuildScope, context: BuildContext) !Element {
            return self.vtable.build(self.ptr, allocator, scope, context);
        }

        pub fn clone(self: CustomElement, allocator: std.mem.Allocator) !CustomElement {
            const clone_fn = self.clone_fn orelse return self;
            return .{
                .ptr = try clone_fn(allocator, self.ptr),
                .vtable = self.vtable,
                .clone_fn = self.clone_fn,
                .destroy_fn = self.destroy_fn,
            };
        }

        pub fn destroy(self: CustomElement, allocator: std.mem.Allocator) void {
            const destroy_fn = self.destroy_fn orelse return;
            destroy_fn(allocator, self.ptr);
        }
    };

    pub const RenderObject = struct {
        ptr: *const anyopaque,
        vtable: *const VTable,
        clone_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) anyerror!*const anyopaque = null,
        destroy_fn: ?*const fn (allocator: std.mem.Allocator, ptr: *const anyopaque) void = null,

        pub const LayoutContext = struct {
            constraints: Constraints,
            measurer: TextMeasurer,
        };

        pub const PaintContext = struct {
            allocator: std.mem.Allocator,
            rect: Rect,
            scale: f32,
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

        pub fn clone(self: RenderObject, allocator: std.mem.Allocator) !RenderObject {
            const clone_fn = self.clone_fn orelse return self;
            return .{
                .ptr = try clone_fn(allocator, self.ptr),
                .vtable = self.vtable,
                .clone_fn = self.clone_fn,
                .destroy_fn = self.destroy_fn,
            };
        }

        pub fn destroy(self: RenderObject, allocator: std.mem.Allocator) void {
            const destroy_fn = self.destroy_fn orelse return;
            destroy_fn(allocator, self.ptr);
        }
    };
};

pub const BuildScope = struct {
    allocator: std.mem.Allocator,
    theme: Theme = .default,
    interaction: InteractionState = .{},
    actions: ?*const ActionScope = null,
    app_context: AppContext = .{},
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

    pub fn borderedBox(allocator: std.mem.Allocator, child: Widget, background: Color, border: ?Color) !Widget {
        return .{ .box = .{ .child = try Widget.alloc(allocator, child), .background = background, .border = border } };
    }

    pub fn clickable(allocator: std.mem.Allocator, id: []const u8, child: Widget, on_click: ?Widget.Callback) !Widget {
        return .{ .clickable = .{ .id = id, .child = try Widget.alloc(allocator, child), .on_click = on_click } };
    }

    pub fn pressClickable(allocator: std.mem.Allocator, id: []const u8, child: Widget, on_click: ?Widget.Callback) !Widget {
        return .{ .clickable = .{ .id = id, .child = try Widget.alloc(allocator, child), .on_click = on_click, .activation = .press } };
    }

    pub fn focus(allocator: std.mem.Allocator, node: FocusNode, child: Widget) !Widget {
        return focusWithOptions(allocator, node, child, .{});
    }

    pub const FocusOptions = struct {
        autofocus: bool = false,
        skip_traversal: bool = false,
        can_request_focus: bool = true,
        on_focus_change: ?Widget.FocusChangeCallback = null,
    };

    pub fn focusWithOptions(allocator: std.mem.Allocator, node: FocusNode, child: Widget, options: FocusOptions) !Widget {
        return .{ .focus = .{
            .node = node,
            .child = try Widget.alloc(allocator, child),
            .autofocus = options.autofocus,
            .skip_traversal = options.skip_traversal,
            .can_request_focus = options.can_request_focus,
            .on_focus_change = options.on_focus_change,
        } };
    }

    pub fn focusScope(allocator: std.mem.Allocator, id: []const u8, child: Widget) !Widget {
        return focusScopeWithOptions(allocator, id, child, .{});
    }

    pub const FocusScopeOptions = struct {
        modal: bool = false,
    };

    pub fn focusScopeWithOptions(allocator: std.mem.Allocator, id: []const u8, child: Widget, options: FocusScopeOptions) !Widget {
        return .{ .focus_scope = .{ .id = id, .child = try Widget.alloc(allocator, child), .modal = options.modal } };
    }

    pub fn button(allocator: std.mem.Allocator, id: []const u8, label: []const u8, on_pressed: ?Widget.Callback) !Widget {
        _ = allocator;
        return .{ .button = .{ .id = id, .label = label, .on_pressed = on_pressed } };
    }

    pub fn actionButton(allocator: std.mem.Allocator, id: []const u8, label: []const u8, action_id: []const u8) !Widget {
        _ = allocator;
        return .{ .button = .{ .id = id, .label = label, .intent = .action(action_id) } };
    }

    pub fn intentButton(allocator: std.mem.Allocator, id: []const u8, label: []const u8, intent: Intent) !Widget {
        _ = allocator;
        return .{ .button = .{ .id = id, .label = label, .intent = intent } };
    }

    pub fn theme(allocator: std.mem.Allocator, theme_value: Theme, child: Widget) !Widget {
        return .{ .theme = .{ .theme = theme_value, .child = try Widget.alloc(allocator, child) } };
    }

    pub fn textInput(id: []const u8, value: []const u8, placeholder: []const u8) Widget {
        return .{ .text_input = .{ .id = id, .focus_node = .named(id), .value = value, .placeholder = placeholder } };
    }

    pub fn textInputWithFocusNode(id: []const u8, focus_node: FocusNode, value: []const u8, placeholder: []const u8) Widget {
        return .{ .text_input = .{ .id = id, .focus_node = focus_node, .value = value, .placeholder = placeholder } };
    }

    pub fn row(allocator: std.mem.Allocator, children: []const Widget, gap: f32) !Widget {
        return .{ .row = .{ .children = try Widget.allocSlice(allocator, children), .gap = gap } };
    }

    pub fn column(allocator: std.mem.Allocator, children: []const Widget, gap: f32) !Widget {
        return .{ .column = .{ .children = try Widget.allocSlice(allocator, children), .gap = gap } };
    }

    pub fn spacer(flex: f32) Widget {
        return .{ .spacer = .{ .flex = @max(0, flex) } };
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

    pub fn actions(allocator: std.mem.Allocator, bindings: []const Widget.ActionBinding, child: Widget) !Widget {
        return .{ .actions = .{ .bindings = try allocator.dupe(Widget.ActionBinding, bindings), .child = try Widget.alloc(allocator, child) } };
    }

    pub fn shortcuts(allocator: std.mem.Allocator, bindings: []const Widget.ShortcutBinding, child: Widget) !Widget {
        return .{ .shortcuts = .{ .bindings = try allocator.dupe(Widget.ShortcutBinding, bindings), .child = try Widget.alloc(allocator, child) } };
    }
};

pub const Element = struct {
    kind: Kind,
    widget: Widget,
    key: ?Widget.Key = null,
    state: ?*anyopaque = null,
    focused: bool = false,
    children: []Element = &.{},

    pub const Kind = enum {
        keyed,
        text,
        box,
        clickable,
        focus,
        focus_scope,
        text_input,
        row,
        column,
        spacer,
        padding,
        center,
        button,
        actions,
        shortcuts,
        theme,
        component,
        stateful,
        element,
        render_object,
    };
};

fn buildButtonWidget(
    allocator: std.mem.Allocator,
    theme: Theme,
    interaction: InteractionState,
    actions: ?*const ActionScope,
    button_widget: Widget.Button,
) !Widget {
    const on_pressed = button_widget.on_pressed orelse if (button_widget.intent) |intent| findActionForIntent(actions, intent) else null;
    const enabled = on_pressed != null;
    const hovered = enabled and interaction.isHovered(button_widget.id);
    const pressed = enabled and interaction.isPressed(button_widget.id);
    const focused = enabled and interaction.isFocused(.named(button_widget.id));
    const label = widgets.coloredText(button_widget.label, buttonForeground(theme, enabled, hovered));
    const padded = try widgets.padding(allocator, EdgeInsets.all(theme.button_theme.padding), label);
    const background = if (!enabled) buttonDisabledBackground(theme) else if (pressed) buttonPressedBackground(theme) else buttonBackground(theme, hovered);
    const surface = try widgets.borderedBox(allocator, padded, background, if (focused) buttonFocusedBorder(theme) else null);
    if (!enabled) return surface;
    const surface_child = try Widget.alloc(allocator, surface);
    return .{ .clickable = .{ .id = button_widget.id, .child = surface_child, .on_click = borrowedCallback(on_pressed.?) } };
}

fn borrowedCallback(callback: Widget.Callback) Widget.Callback {
    return .{ .ptr = callback.ptr, .call_fn = callback.call_fn };
}

fn textColor(theme: Theme) Color {
    return theme.text_theme.body.color orelse theme.color_scheme.on_surface;
}

fn buttonBackground(theme: Theme, hovered: bool) Color {
    if (hovered) return theme.button_theme.hover_background orelse theme.button_theme.background orelse theme.color_scheme.on_surface;
    return theme.button_theme.background orelse theme.color_scheme.primary;
}

fn buttonForeground(theme: Theme, enabled: bool, hovered: bool) Color {
    if (!enabled) return theme.button_theme.disabled_foreground orelse theme.color_scheme.on_surface_variant;
    if (hovered) return theme.button_theme.hover_foreground orelse theme.button_theme.foreground orelse theme.color_scheme.surface;
    return theme.button_theme.foreground orelse theme.color_scheme.on_primary;
}

fn buttonPressedBackground(theme: Theme) Color {
    return theme.button_theme.pressed_background orelse theme.color_scheme.on_surface;
}

fn buttonDisabledBackground(theme: Theme) Color {
    return theme.button_theme.disabled_background orelse theme.color_scheme.surface_variant;
}

fn buttonFocusedBorder(theme: Theme) Color {
    return theme.button_theme.focused_border orelse theme.color_scheme.on_surface;
}

fn inputForeground(theme: Theme) Color {
    return theme.input_theme.foreground orelse theme.color_scheme.on_surface_variant;
}

fn inputBackground(theme: Theme) Color {
    return theme.input_theme.background orelse theme.color_scheme.surface_variant;
}

fn inputBorder(theme: Theme) Color {
    return theme.input_theme.border orelse theme.color_scheme.outline;
}

fn inputFocusedBorder(theme: Theme) Color {
    return theme.input_theme.focused_border orelse theme.color_scheme.primary;
}

fn inputPlaceholder(theme: Theme) Color {
    return theme.input_theme.placeholder orelse theme.color_scheme.on_surface_variant;
}

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
    tap_down_callback: ?Widget.Callback = null,
    tap_up_callback: ?Widget.Callback = null,
    tap_cancel_callback: ?Widget.Callback = null,
    click_activation: Widget.ClickActivation = .release,
    text_input_id: ?[]const u8 = null,
    focus_id: ?[]const u8 = null,
    focus_scope_id: ?[]const u8 = null,
    modal_focus_scope: bool = false,
    autofocus: bool = false,
    skip_traversal: bool = false,
    can_request_focus: bool = true,
    focus_change_callback: ?Widget.FocusChangeCallback = null,
    render_object: ?Widget.RenderObject = null,
    foreground: Color = colors.ink,
    background: Color = colors.transparent,
    box_border: ?Color = null,
    placeholder: ?[]const u8 = null,
    border: Color = colors.ink,
    focused_border: Color = colors.accent,
    placeholder_foreground: Color = Color.argb(0xff, 0x77, 0x77, 0x7d),
    focused: bool = false,
    caret_x: ?f32 = null,
    children: []RenderNode = &.{},

    pub const Kind = enum {
        keyed,
        text,
        box,
        clickable,
        focus,
        focus_scope,
        text_input,
        row,
        column,
        spacer,
        padding,
        center,
        button,
        actions,
        shortcuts,
        theme,
        component,
        stateful,
        element,
        render_object,
    };
};

pub const PaintCommand = union(enum) {
    fill_rect: FillRect,
    text: TextRun,
    alpha_image: AlphaImage,

    pub const FillRect = struct {
        rect: Rect,
        color: Color,
    };

    pub const TextRun = struct {
        origin: Point,
        value: []const u8,
        color: Color,
    };

    pub const AlphaImage = struct {
        rect: Rect,
        width: u32,
        height: u32,
        alpha: []const u8,
        color: Color,
        cache_key: u64,
    };
};

pub const DisplayList = struct {
    commands: std.ArrayList(PaintCommand) = .empty,

    pub fn deinit(self: *DisplayList, allocator: std.mem.Allocator) void {
        self.freeOwnedCommandData(allocator);
        self.commands.deinit(allocator);
    }

    pub fn clearRetainingCapacity(self: *DisplayList, allocator: std.mem.Allocator) void {
        self.freeOwnedCommandData(allocator);
        self.commands.clearRetainingCapacity();
    }

    fn freeOwnedCommandData(self: *DisplayList, allocator: std.mem.Allocator) void {
        for (self.commands.items) |command| switch (command) {
            .alpha_image => |image| allocator.free(image.alpha),
            .fill_rect, .text => {},
        };
    }

    pub fn fillRect(self: *DisplayList, allocator: std.mem.Allocator, rect: Rect, color: Color) !void {
        try self.commands.append(allocator, .{ .fill_rect = .{ .rect = rect, .color = color } });
    }

    pub fn text(self: *DisplayList, allocator: std.mem.Allocator, origin: Point, value: []const u8, color: Color) !void {
        try self.commands.append(allocator, .{ .text = .{ .origin = origin, .value = value, .color = color } });
    }

    pub fn alphaImage(
        self: *DisplayList,
        allocator: std.mem.Allocator,
        rect: Rect,
        width: u32,
        height: u32,
        alpha: []u8,
        color: Color,
        cache_key: u64,
    ) !void {
        errdefer allocator.free(alpha);
        try self.commands.append(allocator, .{ .alpha_image = .{
            .rect = rect,
            .width = width,
            .height = height,
            .alpha = alpha,
            .color = color,
            .cache_key = cache_key,
        } });
    }
};

pub const RenderBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        present: *const fn (ptr: *anyopaque, frame: Frame) anyerror!bool,
        measure_text: *const fn (ptr: *anyopaque, value: []const u8) anyerror!Size,
        scale: *const fn (ptr: *anyopaque) f32,
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

    pub fn scale(self: RenderBackend) f32 {
        return self.vtable.scale(self.ptr);
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
        return .{ .ptr = self, .vtable = &.{ .present = present, .measure_text = measureText, .scale = scale } };
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
                .alpha_image => |image| try self.writer.print(
                    "alpha_image x={d} y={d} w={d} h={d} pixels={d}x{d} color=#{x:0>8}\n",
                    .{ image.rect.x, image.rect.y, image.rect.width, image.rect.height, image.width, image.height, @as(u32, @bitCast(image.color)) },
                ),
            }
        }
        return false;
    }

    fn measureText(_: *anyopaque, value: []const u8) !Size {
        return fixedMeasureText(value);
    }

    fn scale(_: *anyopaque) f32 {
        return 1;
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
    space,
    tab: struct { reverse: bool = false },
};

pub const CursorShape = enum {
    default,
    pointer,
    text,
};

pub const AppContext = struct {
    pulse: bool = false,
    input_text: []const u8 = "",
    window_width: f32 = 0,
    window_height: f32 = 0,
    color_scheme: []const u8 = "no-preference",
};

pub const AppHost = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        build_widget: *const fn (ptr: *anyopaque, scope: *BuildScope, context: AppContext) anyerror!Widget,
        timer: ?*const fn (ptr: *anyopaque, expirations: u64) anyerror!bool = null,
    };

    pub fn buildWidget(self: AppHost, scope: *BuildScope, context: AppContext) !Widget {
        return self.vtable.build_widget(self.ptr, scope, context);
    }

    pub fn timer(self: AppHost, expirations: u64) !bool {
        const timer_fn = self.vtable.timer orelse return false;
        return timer_fn(self.ptr, expirations);
    }
};

pub fn buildRenderTree(allocator: std.mem.Allocator, widget: *const Widget, constraints: Constraints) !RenderNode {
    var scope: BuildScope = .{ .allocator = allocator };
    var element = try buildElementTreeScoped(allocator, &scope, widget, constraints);
    defer destroyElementTree(allocator, &element);
    return layoutElement(allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
}

pub fn buildRenderTreeMeasured(
    allocator: std.mem.Allocator,
    widget: *const Widget,
    constraints: Constraints,
    backend: RenderBackend,
) !RenderNode {
    var scope: BuildScope = .{ .allocator = allocator };
    var element = try buildElementTreeScoped(allocator, &scope, widget, constraints);
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
    var scope: BuildScope = .{ .allocator = allocator };
    return buildElementTreeScoped(allocator, &scope, widget, constraints);
}

pub fn buildElementTreeScoped(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    widget: *const Widget,
    constraints: Constraints,
) anyerror!Element {
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
            children[0] = try buildElementTreeScoped(allocator, scope, keyed_widget.child, constraints);
            initialized = true;
            return .{ .kind = .keyed, .widget = element_widget, .key = element_key, .children = children };
        },
        .text => return .{ .kind = .text, .widget = try cloneWidgetForElementThemed(allocator, widget.*, scope.theme) },
        .spacer => return .{ .kind = .spacer, .widget = try cloneWidgetForElement(allocator, widget.*) },
        .text_input => {
            const element_widget = try cloneWidgetForElementThemed(allocator, widget.*, scope.theme);
            return .{ .kind = .text_input, .widget = element_widget, .focused = scope.interaction.isFocused(element_widget.text_input.focus_node) };
        },
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
            children[0] = try buildElementTreeScoped(allocator, scope, box_widget.child, constraints);
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
            children[0] = try buildElementTreeScoped(allocator, scope, clickable_widget.child, constraints);
            initialized = true;
            return .{ .kind = .clickable, .widget = element_widget, .children = children };
        },
        .focus => |focus_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTreeScoped(allocator, scope, focus_widget.child, constraints);
            initialized = true;
            return .{ .kind = .focus, .widget = element_widget, .focused = scope.interaction.isFocused(element_widget.focus.node), .children = children };
        },
        .focus_scope => |focus_scope_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTreeScoped(allocator, scope, focus_scope_widget.child, constraints);
            initialized = true;
            return .{ .kind = .focus_scope, .widget = element_widget, .children = children };
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
            children[0] = try buildElementTreeScoped(allocator, scope, padding_widget.child, constraints.inset(padding_widget.insets));
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
            children[0] = try buildElementTreeScoped(allocator, scope, center_widget.child, constraints);
            initialized = true;
            return .{ .kind = .center, .widget = element_widget, .children = children };
        },
        .button => {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const built = try buildButtonWidget(scope.allocator, scope.theme, scope.interaction, scope.actions, element_widget.button);
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTreeScoped(allocator, scope, &built, constraints);
            initialized = true;
            return .{ .kind = .button, .widget = element_widget, .children = children };
        },
        .actions => |actions_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const previous_actions = scope.actions;
            const nested_actions: ActionScope = .{ .bindings = element_widget.actions.bindings, .parent = previous_actions };
            scope.actions = &nested_actions;
            defer scope.actions = previous_actions;
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTreeScoped(allocator, scope, actions_widget.child, constraints);
            initialized = true;
            return .{ .kind = .actions, .widget = element_widget, .children = children };
        },
        .shortcuts => |shortcuts_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTreeScoped(allocator, scope, shortcuts_widget.child, constraints);
            initialized = true;
            return .{ .kind = .shortcuts, .widget = element_widget, .children = children };
        },
        .theme => |theme_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const previous_theme = scope.theme;
            scope.theme = theme_widget.theme;
            defer scope.theme = previous_theme;
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTreeScoped(allocator, scope, theme_widget.child, constraints);
            initialized = true;
            return .{ .kind = .theme, .widget = element_widget, .children = children };
        },
        .row => |row_widget| return buildLinearElementTree(allocator, scope, .row, widget.*, row_widget.children, constraints),
        .column => |column_widget| return buildLinearElementTree(allocator, scope, .column, widget.*, column_widget.children, constraints),
        .component => |component_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const built = try component_widget.build(scope, buildContext(scope, constraints));
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTreeScoped(allocator, scope, &built, constraints);
            initialized = true;
            return .{ .kind = .component, .widget = element_widget, .children = children };
        },
        .stateful => |stateful_widget| {
            _ = stateful_widget;
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const retained_stateful = element_widget.stateful;
            const state = try retained_stateful.createState(allocator);
            errdefer retained_stateful.destroyState(state, allocator);
            const built = try retained_stateful.build(state, scope, buildContext(scope, constraints));
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (initialized) destroyElementTree(allocator, &children[0]);
                allocator.free(children);
            }
            children[0] = try buildElementTreeScoped(allocator, scope, &built, constraints);
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
            children[0] = try custom_element.build(allocator, scope, buildContext(scope, constraints));
            initialized = true;
            return .{ .kind = .element, .widget = element_widget, .children = children };
        },
    }
}

fn buildContext(scope: *const BuildScope, constraints: Constraints) Widget.BuildContext {
    return .{
        .constraints = constraints,
        .theme = scope.theme,
        .interaction = scope.interaction,
        .app_context = scope.app_context,
    };
}

fn buildLinearElementTree(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
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
        children[index] = try buildElementTreeScoped(allocator, scope, child_widget, constraints);
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
    var scope: BuildScope = .{ .allocator = allocator };
    try updateElementTreeScoped(allocator, &scope, element, widget, constraints);
}

pub fn updateElementTreeScoped(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    widget: *const Widget,
    constraints: Constraints,
) anyerror!void {
    if (!canUpdateElement(element, widget)) {
        var replacement = try buildElementTreeScoped(allocator, scope, widget, constraints);
        errdefer destroyElementTree(allocator, &replacement);
        destroyElementTree(allocator, element);
        element.* = replacement;
        return;
    }

    switch (widget.*) {
        .keyed => |keyed_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, keyed_widget.child, constraints);
            if (element.key) |old_key| destroyKey(allocator, old_key);
            element.key = try cloneKey(allocator, keyed_widget.key);
        },
        .text => try replaceElementWidgetThemed(allocator, element, widget.*, scope.theme),
        .spacer => try replaceElementWidget(allocator, element, widget.*),
        .text_input => {
            try replaceElementWidgetThemed(allocator, element, widget.*, scope.theme);
            element.focused = scope.interaction.isFocused(element.widget.text_input.focus_node);
        },
        .render_object => try replaceElementWidget(allocator, element, widget.*),
        .box => |box_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, box_widget.child, constraints);
        },
        .clickable => |clickable_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, clickable_widget.child, constraints);
        },
        .focus => |focus_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, focus_widget.child, constraints);
            element.focused = scope.interaction.isFocused(element.widget.focus.node);
        },
        .focus_scope => |focus_scope_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, focus_scope_widget.child, constraints);
        },
        .padding => |padding_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, padding_widget.child, constraints.inset(padding_widget.insets));
        },
        .center => |center_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, center_widget.child, constraints);
        },
        .button => |button_widget| {
            _ = button_widget;
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const built = try buildButtonWidget(scope.allocator, scope.theme, scope.interaction, scope.actions, element_widget.button);
            try updateElementTreeScoped(allocator, scope, &element.children[0], &built, constraints);
            destroyElementWidget(allocator, &element.widget);
            element.widget = element_widget;
        },
        .actions => |actions_widget| {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer destroyElementWidget(allocator, &element_widget);
            const previous_actions = scope.actions;
            const nested_actions: ActionScope = .{ .bindings = element_widget.actions.bindings, .parent = previous_actions };
            scope.actions = &nested_actions;
            defer scope.actions = previous_actions;
            try updateElementTreeScoped(allocator, scope, &element.children[0], actions_widget.child, constraints);
            destroyElementWidget(allocator, &element.widget);
            element.widget = element_widget;
        },
        .shortcuts => |shortcuts_widget| {
            try updateSingleChildElement(allocator, scope, element, widget.*, shortcuts_widget.child, constraints);
        },
        .theme => |theme_widget| {
            const previous_theme = scope.theme;
            scope.theme = theme_widget.theme;
            defer scope.theme = previous_theme;
            try updateSingleChildElement(allocator, scope, element, widget.*, theme_widget.child, constraints);
        },
        .row => |row_widget| try updateLinearElement(allocator, scope, element, widget.*, row_widget.children, constraints),
        .column => |column_widget| try updateLinearElement(allocator, scope, element, widget.*, column_widget.children, constraints),
        .component => |component_widget| {
            const built = try component_widget.build(scope, buildContext(scope, constraints));
            try updateSingleChildElement(allocator, scope, element, widget.*, &built, constraints);
        },
        .stateful => |stateful_widget| {
            const state = element.state orelse return error.MissingState;
            try stateful_widget.update(state, allocator, buildContext(scope, constraints));
            const built = try stateful_widget.build(state, scope, buildContext(scope, constraints));
            try updateSingleChildElement(allocator, scope, element, widget.*, &built, constraints);
        },
        .element => |custom_element| {
            var replacement_child = try custom_element.build(allocator, scope, buildContext(scope, constraints));
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

pub fn rebuildDirtyElementTreeScoped(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    constraints: Constraints,
) anyerror!bool {
    switch (element.widget) {
        .text,
        .spacer,
        .text_input,
        .render_object,
        .button,
        => return false,

        .keyed,
        .box,
        .clickable,
        .focus,
        .focus_scope,
        .center,
        .component,
        .element,
        .shortcuts,
        => return try rebuildDirtySingleChildElement(allocator, scope, element, constraints),

        .padding => |padding_widget| return try rebuildDirtySingleChildElement(allocator, scope, element, constraints.inset(padding_widget.insets)),
        .theme => |theme_widget| {
            const previous_theme = scope.theme;
            scope.theme = theme_widget.theme;
            defer scope.theme = previous_theme;
            return try rebuildDirtySingleChildElement(allocator, scope, element, constraints);
        },
        .actions => |actions_widget| {
            const previous_actions = scope.actions;
            const nested_actions: ActionScope = .{ .bindings = actions_widget.bindings, .parent = previous_actions };
            scope.actions = &nested_actions;
            defer scope.actions = previous_actions;
            return try rebuildDirtySingleChildElement(allocator, scope, element, constraints);
        },
        .row, .column => return try rebuildDirtyChildren(allocator, scope, element.children, constraints),
        .stateful => |stateful_widget| {
            const state = element.state orelse return error.MissingState;
            if (stateful_widget.needsRebuild(state)) {
                const built = try stateful_widget.build(state, scope, buildContext(scope, constraints));
                try updateElementTreeScoped(allocator, scope, &element.children[0], &built, constraints);
                stateful_widget.clearRebuild(state);
                return true;
            }
            return try rebuildDirtySingleChildElement(allocator, scope, element, constraints);
        },
    }
}

fn rebuildDirtySingleChildElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    constraints: Constraints,
) !bool {
    std.debug.assert(element.children.len == 1);
    return rebuildDirtyElementTreeScoped(allocator, scope, &element.children[0], constraints);
}

fn rebuildDirtyChildren(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    children: []Element,
    constraints: Constraints,
) !bool {
    var rebuilt = false;
    for (children) |*child| {
        if (try rebuildDirtyElementTreeScoped(allocator, scope, child, constraints)) rebuilt = true;
    }
    return rebuilt;
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
        .focus => .focus,
        .focus_scope => .focus_scope,
        .text_input => .text_input,
        .row => .row,
        .column => .column,
        .spacer => .spacer,
        .padding => .padding,
        .center => .center,
        .button => .button,
        .actions => .actions,
        .shortcuts => .shortcuts,
        .theme => .theme,
        .component => .component,
        .stateful => .stateful,
        .element => .element,
        .render_object => .render_object,
    };
}

fn updateSingleChildElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    widget: Widget,
    child_widget: *const Widget,
    child_constraints: Constraints,
) anyerror!void {
    std.debug.assert(element.children.len == 1);
    var element_widget = try cloneWidgetForElement(allocator, widget);
    errdefer destroyElementWidget(allocator, &element_widget);
    try updateElementTreeScoped(allocator, scope, &element.children[0], child_widget, child_constraints);
    destroyElementWidget(allocator, &element.widget);
    element.widget = element_widget;
}

fn updateLinearElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    widget: Widget,
    child_widgets: []const Widget,
    constraints: Constraints,
) anyerror!void {
    if (hasKeyedChildren(element.children) or hasKeyedWidgets(child_widgets)) {
        try updateKeyedLinearElement(allocator, scope, element, widget, child_widgets, constraints);
        return;
    }

    if (element.children.len != child_widgets.len) {
        var replacement = try buildElementTreeScoped(allocator, scope, &widget, constraints);
        errdefer destroyElementTree(allocator, &replacement);
        destroyElementTree(allocator, element);
        element.* = replacement;
        return;
    }

    var element_widget = try cloneWidgetForElement(allocator, widget);
    errdefer destroyElementWidget(allocator, &element_widget);
    for (child_widgets, 0..) |*child_widget, index| {
        try updateElementTreeScoped(allocator, scope, &element.children[index], child_widget, constraints);
    }
    destroyElementWidget(allocator, &element.widget);
    element.widget = element_widget;
}

fn updateKeyedLinearElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
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
                try updateElementTreeScoped(allocator, scope, &new_children[index], child_widget, constraints);
                initialized += 1;
                continue;
            }
        } else if (index < old_children.len and !used[index] and old_children[index].key == null) {
            used[index] = true;
            new_children[index] = old_children[index];
            try updateElementTreeScoped(allocator, scope, &new_children[index], child_widget, constraints);
            initialized += 1;
            continue;
        }

        new_children[index] = try buildElementTreeScoped(allocator, scope, child_widget, constraints);
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

fn replaceElementWidgetThemed(allocator: std.mem.Allocator, element: *Element, widget: Widget, theme: Theme) anyerror!void {
    var element_widget = try cloneWidgetForElementThemed(allocator, widget, theme);
    errdefer destroyElementWidget(allocator, &element_widget);
    destroyElementWidget(allocator, &element.widget);
    element.widget = element_widget;
}

fn cloneWidgetForElementThemed(allocator: std.mem.Allocator, widget: Widget, theme: Theme) !Widget {
    var result = try cloneWidgetForElement(allocator, widget);
    switch (result) {
        .text => |*text_widget| {
            if (text_widget.color == null) text_widget.color = textColor(theme);
        },
        .text_input => |*input_widget| {
            input_widget.foreground = inputForeground(theme);
            input_widget.background = inputBackground(theme);
            input_widget.border = inputBorder(theme);
            input_widget.focused_border = inputFocusedBorder(theme);
            input_widget.placeholder_foreground = inputPlaceholder(theme);
        },
        else => {},
    }
    return result;
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
        .spacer => |spacer_widget| .{ .spacer = spacer_widget },
        .button => |button_widget| blk: {
            const id = try allocator.dupe(u8, button_widget.id);
            errdefer allocator.free(id);
            const label = try allocator.dupe(u8, button_widget.label);
            errdefer allocator.free(label);
            const intent = if (button_widget.intent) |intent_value| try cloneIntent(allocator, intent_value) else null;
            errdefer if (intent) |intent_value| destroyIntent(allocator, intent_value);
            const callback = if (button_widget.on_pressed) |on_pressed| try on_pressed.clone(allocator) else null;
            errdefer if (callback) |on_pressed| on_pressed.destroy(allocator);
            break :blk .{ .button = .{ .id = id, .label = label, .on_pressed = callback, .intent = intent } };
        },
        .box => |box_widget| .{ .box = box_widget },
        .clickable => |clickable_widget| blk: {
            const id = try allocator.dupe(u8, clickable_widget.id);
            errdefer allocator.free(id);
            const callback = if (clickable_widget.on_click) |on_click| try on_click.clone(allocator) else null;
            errdefer if (callback) |on_click| on_click.destroy(allocator);
            const tap_down = if (clickable_widget.on_tap_down) |on_tap_down| try on_tap_down.clone(allocator) else null;
            errdefer if (tap_down) |on_tap_down| on_tap_down.destroy(allocator);
            const tap_up = if (clickable_widget.on_tap_up) |on_tap_up| try on_tap_up.clone(allocator) else null;
            errdefer if (tap_up) |on_tap_up| on_tap_up.destroy(allocator);
            const tap_cancel = if (clickable_widget.on_tap_cancel) |on_tap_cancel| try on_tap_cancel.clone(allocator) else null;
            errdefer if (tap_cancel) |on_tap_cancel| on_tap_cancel.destroy(allocator);
            break :blk .{ .clickable = .{
                .id = id,
                .child = clickable_widget.child,
                .on_click = callback,
                .on_tap_down = tap_down,
                .on_tap_up = tap_up,
                .on_tap_cancel = tap_cancel,
                .activation = clickable_widget.activation,
            } };
        },
        .focus => |focus_widget| blk: {
            const focus_id = try allocator.dupe(u8, focus_widget.node.id);
            errdefer allocator.free(focus_id);
            const focus_change_callback = if (focus_widget.on_focus_change) |callback| try callback.clone(allocator) else null;
            errdefer if (focus_change_callback) |callback| callback.destroy(allocator);
            break :blk .{ .focus = .{
                .node = .named(focus_id),
                .child = focus_widget.child,
                .autofocus = focus_widget.autofocus,
                .skip_traversal = focus_widget.skip_traversal,
                .can_request_focus = focus_widget.can_request_focus,
                .on_focus_change = focus_change_callback,
            } };
        },
        .focus_scope => |focus_scope_widget| blk: {
            const id = try allocator.dupe(u8, focus_scope_widget.id);
            break :blk .{ .focus_scope = .{ .id = id, .child = focus_scope_widget.child, .modal = focus_scope_widget.modal } };
        },
        .text_input => |input_widget| blk: {
            const id = try allocator.dupe(u8, input_widget.id);
            errdefer allocator.free(id);
            const focus_node_id = try allocator.dupe(u8, input_widget.focus_node.id);
            errdefer allocator.free(focus_node_id);
            const value = try allocator.dupe(u8, input_widget.value);
            errdefer allocator.free(value);
            const placeholder = try allocator.dupe(u8, input_widget.placeholder);
            break :blk .{ .text_input = .{
                .id = id,
                .focus_node = .named(focus_node_id),
                .value = value,
                .placeholder = placeholder,
                .foreground = input_widget.foreground,
                .background = input_widget.background,
                .border = input_widget.border,
                .focused_border = input_widget.focused_border,
                .placeholder_foreground = input_widget.placeholder_foreground,
            } };
        },
        .row => |row_widget| .{ .row = .{ .children = &.{}, .gap = row_widget.gap } },
        .column => |column_widget| .{ .column = .{ .children = &.{}, .gap = column_widget.gap } },
        .padding => |padding_widget| .{ .padding = padding_widget },
        .center => |center_widget| .{ .center = center_widget },
        .actions => |actions_widget| .{ .actions = .{
            .bindings = try cloneActionBindings(allocator, actions_widget.bindings),
            .child = actions_widget.child,
        } },
        .shortcuts => |shortcuts_widget| .{ .shortcuts = .{
            .bindings = try cloneShortcutBindings(allocator, shortcuts_widget.bindings),
            .child = shortcuts_widget.child,
        } },
        .theme => |theme_widget| .{ .theme = theme_widget },
        .component => |component_widget| .{ .component = component_widget },
        .stateful => |stateful_widget| .{ .stateful = try stateful_widget.clone(allocator) },
        .element => |custom_element| .{ .element = try custom_element.clone(allocator) },
        .render_object => |render_object| .{ .render_object = try render_object.clone(allocator) },
    };
}

fn destroyElementWidget(allocator: std.mem.Allocator, widget: *Widget) void {
    switch (widget.*) {
        .keyed => |keyed_widget| destroyKey(allocator, keyed_widget.key),
        .text => |text_widget| allocator.free(text_widget.value),
        .spacer => {},
        .button => |button_widget| {
            if (button_widget.on_pressed) |callback| callback.destroy(allocator);
            allocator.free(button_widget.id);
            allocator.free(button_widget.label);
            if (button_widget.intent) |intent| destroyIntent(allocator, intent);
        },
        .clickable => |clickable_widget| {
            if (clickable_widget.on_click) |callback| callback.destroy(allocator);
            if (clickable_widget.on_tap_down) |callback| callback.destroy(allocator);
            if (clickable_widget.on_tap_up) |callback| callback.destroy(allocator);
            if (clickable_widget.on_tap_cancel) |callback| callback.destroy(allocator);
            allocator.free(clickable_widget.id);
        },
        .focus => |focus_widget| {
            if (focus_widget.on_focus_change) |callback| callback.destroy(allocator);
            allocator.free(focus_widget.node.id);
        },
        .focus_scope => |focus_scope_widget| allocator.free(focus_scope_widget.id),
        .text_input => |input_widget| {
            allocator.free(input_widget.id);
            allocator.free(input_widget.focus_node.id);
            allocator.free(input_widget.value);
            allocator.free(input_widget.placeholder);
        },
        .stateful => |stateful_widget| stateful_widget.destroy(allocator),
        .render_object => |render_object| render_object.destroy(allocator),
        .element => |custom_element| custom_element.destroy(allocator),
        .actions => |actions_widget| destroyActionBindings(allocator, actions_widget.bindings),
        .shortcuts => |shortcuts_widget| destroyShortcutBindings(allocator, shortcuts_widget.bindings),
        .box, .row, .column, .padding, .center, .theme, .component => {},
    }
}

fn cloneActionBindings(allocator: std.mem.Allocator, bindings: []const Widget.ActionBinding) ![]Widget.ActionBinding {
    const result = try allocator.alloc(Widget.ActionBinding, bindings.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |binding| {
            allocator.free(binding.id);
            binding.callback.destroy(allocator);
        }
        allocator.free(result);
    }
    for (bindings, 0..) |binding, index| {
        const id = try allocator.dupe(u8, binding.id);
        const callback = binding.callback.clone(allocator) catch |err| {
            allocator.free(id);
            return err;
        };
        result[index] = .{ .id = id, .callback = callback };
        initialized += 1;
    }
    return result;
}

fn destroyActionBindings(allocator: std.mem.Allocator, bindings: []const Widget.ActionBinding) void {
    for (bindings) |binding| {
        allocator.free(binding.id);
        binding.callback.destroy(allocator);
    }
    allocator.free(bindings);
}

fn cloneShortcutBindings(allocator: std.mem.Allocator, bindings: []const Widget.ShortcutBinding) ![]Widget.ShortcutBinding {
    const result = try allocator.alloc(Widget.ShortcutBinding, bindings.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |binding| destroyIntent(allocator, binding.intent);
        allocator.free(result);
    }
    for (bindings, 0..) |binding, index| {
        result[index] = .{ .key = binding.key, .intent = try cloneIntent(allocator, binding.intent) };
        initialized += 1;
    }
    return result;
}

fn destroyShortcutBindings(allocator: std.mem.Allocator, bindings: []const Widget.ShortcutBinding) void {
    for (bindings) |binding| destroyIntent(allocator, binding.intent);
    allocator.free(bindings);
}

fn cloneIntent(allocator: std.mem.Allocator, intent: Intent) !Intent {
    return .{ .action_id = try allocator.dupe(u8, intent.action_id) };
}

fn destroyIntent(allocator: std.mem.Allocator, intent: Intent) void {
    allocator.free(intent.action_id);
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
    if (node.focus_id) |id| allocator.free(id);
    if (node.focus_scope_id) |id| allocator.free(id);
    if (node.placeholder) |placeholder| allocator.free(placeholder);
}

pub fn paint(allocator: std.mem.Allocator, node: *const RenderNode, display_list: *DisplayList) !void {
    return paintScaled(allocator, node, display_list, 1);
}

pub fn paintScaled(allocator: std.mem.Allocator, node: *const RenderNode, display_list: *DisplayList, scale: f32) !void {
    switch (node.kind) {
        .render_object => {
            const render_object = node.render_object orelse return error.MissingRenderObject;
            try render_object.paint(.{ .allocator = allocator, .rect = node.rect, .scale = scale, .display_list = display_list });
        },
        .box => {
            if (node.background.a > 0) try display_list.fillRect(allocator, node.rect, node.background);
            if (node.box_border) |border| try paintBorder(allocator, display_list, node.rect, border);
        },
        .text_input => {
            try display_list.fillRect(allocator, node.rect, node.background);
            try paintBorder(allocator, display_list, node.rect, if (node.focused) node.focused_border else node.border);
            const value = node.text orelse "";
            const visible_text = if (value.len > 0) value else node.placeholder orelse "";
            const text_color = if (value.len > 0) node.foreground else node.placeholder_foreground;
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
                }, node.foreground);
            }
        },
        .text => if (node.text) |value| {
            try display_list.text(allocator, .{ .x = node.rect.x, .y = node.rect.y }, value, node.foreground);
        },
        else => {},
    }

    for (node.children) |*child| {
        try paintScaled(allocator, child, display_list, scale);
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
    tap_down: ?Widget.Callback = null,
    tap_up: ?Widget.Callback = null,
    tap_cancel: ?Widget.Callback = null,
    activation: Widget.ClickActivation = .release,
};

pub const FocusTarget = struct {
    id: []const u8,
    kind: Kind,
    callback: ?Widget.Callback = null,
    scope_id: ?[]const u8 = null,
    modal_scope_id: ?[]const u8 = null,
    autofocus: bool = false,
    skip_traversal: bool = false,
    can_request_focus: bool = true,
    focus_change_callback: ?Widget.FocusChangeCallback = null,

    pub const Kind = enum {
        text_input,
        clickable,
        focus,
    };
};

pub fn collectFocusTargets(allocator: std.mem.Allocator, node: *const RenderNode) ![]FocusTarget {
    var targets: std.ArrayList(FocusTarget) = .empty;
    errdefer targets.deinit(allocator);
    try appendFocusTargets(allocator, &targets, node, null, null);
    return try targets.toOwnedSlice(allocator);
}

fn appendFocusTargets(
    allocator: std.mem.Allocator,
    targets: *std.ArrayList(FocusTarget),
    node: *const RenderNode,
    scope_id: ?[]const u8,
    modal_scope_id: ?[]const u8,
) !void {
    const active_scope_id = node.focus_scope_id orelse scope_id;
    const active_modal_scope_id = if (node.modal_focus_scope) node.focus_scope_id else modal_scope_id;
    switch (node.kind) {
        .text_input => if (node.focus_id) |id| try targets.append(allocator, .{ .id = id, .kind = .text_input, .scope_id = active_scope_id, .modal_scope_id = active_modal_scope_id }),
        .focus => if (node.focus_id) |id| try targets.append(allocator, .{
            .id = id,
            .kind = .focus,
            .scope_id = active_scope_id,
            .modal_scope_id = active_modal_scope_id,
            .autofocus = node.autofocus,
            .skip_traversal = node.skip_traversal,
            .can_request_focus = node.can_request_focus,
            .focus_change_callback = node.focus_change_callback,
        }),
        .clickable => if (node.click_callback) |callback| {
            if (node.clickable_id) |id| try targets.append(allocator, .{ .id = id, .kind = .clickable, .callback = callback, .scope_id = active_scope_id, .modal_scope_id = active_modal_scope_id });
        },
        else => {},
    }
    for (node.children) |*child| {
        try appendFocusTargets(allocator, targets, child, active_scope_id, active_modal_scope_id);
    }
}

pub fn findFocusTarget(node: *const RenderNode, id: []const u8) ?FocusTarget {
    return findFocusTargetScoped(node, id, null, null);
}

fn findFocusTargetScoped(node: *const RenderNode, id: []const u8, scope_id: ?[]const u8, modal_scope_id: ?[]const u8) ?FocusTarget {
    const active_scope_id = node.focus_scope_id orelse scope_id;
    const active_modal_scope_id = if (node.modal_focus_scope) node.focus_scope_id else modal_scope_id;
    switch (node.kind) {
        .text_input => if (node.focus_id) |focus_id| {
            if (std.mem.eql(u8, focus_id, id)) return .{ .id = focus_id, .kind = .text_input, .scope_id = active_scope_id, .modal_scope_id = active_modal_scope_id };
        },
        .focus => if (node.focus_id) |focus_id| {
            if (std.mem.eql(u8, focus_id, id)) return .{
                .id = focus_id,
                .kind = .focus,
                .scope_id = active_scope_id,
                .modal_scope_id = active_modal_scope_id,
                .autofocus = node.autofocus,
                .skip_traversal = node.skip_traversal,
                .can_request_focus = node.can_request_focus,
                .focus_change_callback = node.focus_change_callback,
            };
        },
        .clickable => if (node.click_callback) |callback| {
            if (node.clickable_id) |clickable_id| {
                if (std.mem.eql(u8, clickable_id, id)) return .{ .id = clickable_id, .kind = .clickable, .callback = callback, .scope_id = active_scope_id, .modal_scope_id = active_modal_scope_id };
            }
        },
        else => {},
    }
    for (node.children) |*child| {
        if (findFocusTargetScoped(child, id, active_scope_id, active_modal_scope_id)) |target| return target;
    }
    return null;
}

pub fn hitTestClick(node: *const RenderNode, point: Point) ?ClickHit {
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (hitTestClick(&node.children[index], point)) |hit| return hit;
    }

    if (node.kind == .clickable and node.rect.contains(point)) {
        if (!nodeHasTapCallback(node)) return null;
        return .{
            .id = node.clickable_id orelse return null,
            .callback = node.click_callback,
            .tap_down = node.tap_down_callback,
            .tap_up = node.tap_up_callback,
            .tap_cancel = node.tap_cancel_callback,
            .activation = node.click_activation,
        };
    }
    if (node.kind == .render_object) {
        if (node.render_object) |render_object| {
            if (render_object.hitTest(node.rect, point)) |id| return .{ .id = id };
        }
    }
    return null;
}

pub fn findClickHitById(node: *const RenderNode, id: []const u8) ?ClickHit {
    if (node.kind == .clickable) {
        if (node.clickable_id) |clickable_id| {
            if (std.mem.eql(u8, clickable_id, id) and nodeHasTapCallback(node)) return .{
                .id = clickable_id,
                .callback = node.click_callback,
                .tap_down = node.tap_down_callback,
                .tap_up = node.tap_up_callback,
                .tap_cancel = node.tap_cancel_callback,
                .activation = node.click_activation,
            };
        }
    }
    for (node.children) |*child| {
        if (findClickHitById(child, id)) |hit| return hit;
    }
    return null;
}

fn nodeHasTapCallback(node: *const RenderNode) bool {
    return node.click_callback != null or
        node.tap_down_callback != null or
        node.tap_up_callback != null or
        node.tap_cancel_callback != null;
}

pub fn hitTestTextInput(node: *const RenderNode, point: Point) ?[]const u8 {
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (hitTestTextInput(&node.children[index], point)) |id| return id;
    }

    if (node.kind == .text_input and node.rect.contains(point)) {
        return node.focus_id;
    }
    return null;
}

pub fn hitTestCursorShape(node: *const RenderNode, point: Point) CursorShape {
    if (hitTestTextInput(node, point) != null) return .text;
    if (hitTestClick(node, point) != null) return .pointer;
    return .default;
}

pub fn shortcutKeyForInput(input: KeyInput) ?ShortcutKey {
    return switch (input) {
        .enter => .enter,
        .space => .space,
        .backspace => .backspace,
        .text, .tab => null,
    };
}

pub fn findShortcutAction(element: *const Element, key: ShortcutKey) ?Widget.Callback {
    return findShortcutActionScoped(element, key, null);
}

pub fn findFocusedShortcutAction(element: *const Element, key: ShortcutKey, focused_id: []const u8) ?Widget.Callback {
    return findFocusedShortcutActionScoped(element, key, focused_id, null, null);
}

const ActionScope = struct {
    bindings: []const Widget.ActionBinding,
    parent: ?*const ActionScope = null,
};

const ShortcutScope = struct {
    bindings: []const Widget.ShortcutBinding,
    parent: ?*const ShortcutScope = null,
};

fn findShortcutActionScoped(element: *const Element, key: ShortcutKey, scope: ?*const ActionScope) ?Widget.Callback {
    switch (element.widget) {
        .actions => |actions_widget| {
            const nested: ActionScope = .{ .bindings = actions_widget.bindings, .parent = scope };
            for (element.children) |*child| {
                if (findShortcutActionScoped(child, key, &nested)) |callback| return callback;
            }
            return null;
        },
        else => {},
    }

    switch (element.widget) {
        .shortcuts => |shortcuts_widget| {
            for (shortcuts_widget.bindings) |binding| {
                if (binding.key != key) continue;
                if (findActionForIntent(scope, binding.intent)) |callback| return callback;
            }
        },
        else => {},
    }

    for (element.children) |*child| {
        if (findShortcutActionScoped(child, key, scope)) |callback| return callback;
    }
    return null;
}

fn findActionForIntent(scope: ?*const ActionScope, intent: Intent) ?Widget.Callback {
    var cursor = scope;
    while (cursor) |action_scope| {
        for (action_scope.bindings) |binding| {
            if (std.mem.eql(u8, binding.id, intent.action_id)) return binding.callback;
        }
        cursor = action_scope.parent;
    }
    return null;
}

fn findFocusedShortcutActionScoped(
    element: *const Element,
    key: ShortcutKey,
    focused_id: []const u8,
    actions: ?*const ActionScope,
    shortcuts: ?*const ShortcutScope,
) ?Widget.Callback {
    switch (element.widget) {
        .actions => |actions_widget| {
            const nested_actions: ActionScope = .{ .bindings = actions_widget.bindings, .parent = actions };
            return findFocusedShortcutActionInChildren(element, key, focused_id, &nested_actions, shortcuts);
        },
        .shortcuts => |shortcuts_widget| {
            const nested_shortcuts: ShortcutScope = .{ .bindings = shortcuts_widget.bindings, .parent = shortcuts };
            if (elementIsFocused(element, focused_id)) return findShortcutInScope(&nested_shortcuts, key, actions);
            return findFocusedShortcutActionInChildren(element, key, focused_id, actions, &nested_shortcuts);
        },
        else => {
            if (elementIsFocused(element, focused_id)) return findShortcutInScope(shortcuts, key, actions);
            return findFocusedShortcutActionInChildren(element, key, focused_id, actions, shortcuts);
        },
    }
}

fn findFocusedShortcutActionInChildren(
    element: *const Element,
    key: ShortcutKey,
    focused_id: []const u8,
    actions: ?*const ActionScope,
    shortcuts: ?*const ShortcutScope,
) ?Widget.Callback {
    for (element.children) |*child| {
        if (findFocusedShortcutActionScoped(child, key, focused_id, actions, shortcuts)) |callback| return callback;
    }
    return null;
}

fn findShortcutInScope(scope: ?*const ShortcutScope, key: ShortcutKey, actions: ?*const ActionScope) ?Widget.Callback {
    var cursor = scope;
    while (cursor) |shortcut_scope| {
        for (shortcut_scope.bindings) |binding| {
            if (binding.key != key) continue;
            if (findActionForIntent(actions, binding.intent)) |callback| return callback;
        }
        cursor = shortcut_scope.parent;
    }
    return null;
}

fn elementIsFocused(element: *const Element, focused_id: []const u8) bool {
    return switch (element.widget) {
        .button => |button_widget| std.mem.eql(u8, button_widget.id, focused_id),
        .clickable => |clickable_widget| std.mem.eql(u8, clickable_widget.id, focused_id),
        .focus => |focus_widget| std.mem.eql(u8, focus_widget.node.id, focused_id),
        .text_input => |input_widget| std.mem.eql(u8, input_widget.focus_node.id, focused_id),
        else => false,
    };
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
                .foreground = text_widget.color orelse colors.ink,
            };
        },
        .spacer => return .{
            .kind = .spacer,
            .rect = .{ .x = origin.x, .y = origin.y, .width = 0, .height = 0 },
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
                .box_border = box_widget.border,
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
                .tap_down_callback = clickable_widget.on_tap_down,
                .tap_up_callback = clickable_widget.on_tap_up,
                .tap_cancel_callback = clickable_widget.on_tap_cancel,
                .click_activation = clickable_widget.activation,
                .children = children,
            };
        },
        .focus => |focus_widget| {
            const focus_id = try allocator.dupe(u8, focus_widget.node.id);
            errdefer allocator.free(focus_id);
            var child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            errdefer destroyRenderTree(allocator, &child);

            const children = try allocator.alloc(RenderNode, 1);
            children[0] = child;
            return .{
                .kind = .focus,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .focus_id = focus_id,
                .focused = element.focused,
                .autofocus = focus_widget.autofocus,
                .skip_traversal = focus_widget.skip_traversal,
                .can_request_focus = focus_widget.can_request_focus,
                .focus_change_callback = focus_widget.on_focus_change,
                .children = children,
            };
        },
        .focus_scope => |focus_scope_widget| {
            const scope_id = try allocator.dupe(u8, focus_scope_widget.id);
            errdefer allocator.free(scope_id);
            var child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            errdefer destroyRenderTree(allocator, &child);

            const children = try allocator.alloc(RenderNode, 1);
            children[0] = child;
            return .{
                .kind = .focus_scope,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .focus_scope_id = scope_id,
                .modal_focus_scope = focus_scope_widget.modal,
                .children = children,
            };
        },
        .text_input => |input_widget| {
            const value = try allocator.dupe(u8, input_widget.value);
            errdefer allocator.free(value);
            const id = try allocator.dupe(u8, input_widget.id);
            errdefer allocator.free(id);
            const focus_id = try allocator.dupe(u8, input_widget.focus_node.id);
            errdefer allocator.free(focus_id);
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
                .focus_id = focus_id,
                .foreground = input_widget.foreground,
                .background = input_widget.background,
                .placeholder = placeholder,
                .border = input_widget.border,
                .focused_border = input_widget.focused_border,
                .placeholder_foreground = input_widget.placeholder_foreground,
                .focused = element.focused,
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
        .button => |button_widget| {
            _ = button_widget;
            var child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            errdefer destroyRenderTree(allocator, &child);

            const children = try allocator.alloc(RenderNode, 1);
            children[0] = child;
            return .{
                .kind = .button,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .children = children,
            };
        },
        .actions => |actions_widget| {
            _ = actions_widget;
            var child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            errdefer destroyRenderTree(allocator, &child);

            const children = try allocator.alloc(RenderNode, 1);
            children[0] = child;
            return .{
                .kind = .actions,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .children = children,
            };
        },
        .shortcuts => |shortcuts_widget| {
            _ = shortcuts_widget;
            var child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            errdefer destroyRenderTree(allocator, &child);

            const children = try allocator.alloc(RenderNode, 1);
            children[0] = child;
            return .{
                .kind = .shortcuts,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .children = children,
            };
        },
        .theme => |theme_widget| {
            _ = theme_widget;
            var child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            errdefer destroyRenderTree(allocator, &child);

            const children = try allocator.alloc(RenderNode, 1);
            children[0] = child;
            return .{
                .kind = .theme,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
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

    const total_gap = if (elements.len > 0) gap * @as(f32, @floatFromInt(elements.len - 1)) else 0;
    var fixed_main: f32 = 0;
    var cross: f32 = 0;
    var total_flex: f32 = 0;

    for (elements, 0..) |*child_element, index| {
        if (child_element.widget == .spacer) {
            total_flex += child_element.widget.spacer.flex;
            children[index] = .{
                .kind = .spacer,
                .rect = .{ .x = origin.x, .y = origin.y, .width = 0, .height = 0 },
            };
            initialized += 1;
            continue;
        }

        const remaining = switch (kind) {
            .row => Constraints{ .max_width = constraints.max_width, .max_height = constraints.max_height },
            .column => Constraints{ .max_width = constraints.max_width, .max_height = constraints.max_height },
            else => unreachable,
        };
        children[index] = try layoutElement(allocator, child_element, remaining, origin, measurer);
        initialized += 1;

        switch (kind) {
            .row => {
                fixed_main += children[index].rect.width;
                cross = @max(cross, children[index].rect.height);
            },
            .column => {
                fixed_main += children[index].rect.height;
                cross = @max(cross, children[index].rect.width);
            },
            else => unreachable,
        }
    }

    const max_main = switch (kind) {
        .row => constraints.max_width,
        .column => constraints.max_height,
        else => unreachable,
    };
    const spare = @max(0, max_main - fixed_main - total_gap);
    var cursor = origin;
    var main: f32 = 0;
    for (elements, 0..) |*child_element, index| {
        if (child_element.widget == .spacer and total_flex > 0) {
            const spacer_main = spare * child_element.widget.spacer.flex / total_flex;
            children[index].rect = switch (kind) {
                .row => .{ .x = cursor.x, .y = origin.y, .width = spacer_main, .height = cross },
                .column => .{ .x = origin.x, .y = cursor.y, .width = cross, .height = spacer_main },
                else => unreachable,
            };
        } else {
            const dx = cursor.x - children[index].rect.x;
            const dy = cursor.y - children[index].rect.y;
            children[index].rect.x = cursor.x;
            children[index].rect.y = cursor.y;
            translateChildren(&children[index], dx, dy);
        }

        switch (kind) {
            .row => {
                cursor.x += children[index].rect.width + gap;
                main += children[index].rect.width;
            },
            .column => {
                cursor.y += children[index].rect.height + gap;
                main += children[index].rect.height;
            },
            else => unreachable,
        }
    }
    main += total_gap;

    const size_value = switch (kind) {
        .row => constraints.clamp(.{ .width = main, .height = cross }),
        .column => constraints.clamp(.{ .width = cross, .height = main }),
        else => unreachable,
    };
    return .{
        .kind = kind,
        .rect = switch (kind) {
            .row => .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
            .column => .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
            else => unreachable,
        },
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

var test_callback_state: u8 = 0;

fn testCallback() Widget.Callback {
    return .{ .ptr = &test_callback_state, .call_fn = testCallbackCall };
}

fn testCallbackCall(_: *anyopaque) !void {}

test "layout, paint, and hit test a padded column" {
    const allocator = std.testing.allocator;

    const title: Widget = .{ .text = .{ .value = "Title" } };
    const label: Widget = .{ .text = .{ .value = "OK", .color = colors.white } };
    const button_padding: Widget = .{ .padding = .{ .insets = EdgeInsets.all(8), .child = &label } };
    const button_box: Widget = .{ .box = .{ .background = colors.accent, .child = &button_padding } };
    const button: Widget = .{ .clickable = .{ .id = "ok", .child = &button_box, .on_click = testCallback() } };
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

test "button widget composes styled clickable content" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const button_widget = try widgets.button(build_arena.allocator(), "confirm", "Confirm", testCallback());
    var scope: BuildScope = .{ .allocator = build_arena.allocator(), .interaction = .{ .pressed_id = "confirm" } };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &button_widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(retained_allocator, &element);
    var root = try buildRenderTreeFromElement(retained_allocator, &element, .{ .max_width = 200, .max_height = 80 }, .fixed);
    defer destroyRenderTree(retained_allocator, &root);

    try std.testing.expectEqual(@as(RenderNode.Kind, .button), root.kind);
    try std.testing.expectEqual(@as(RenderNode.Kind, .clickable), root.children[0].kind);
    try std.testing.expectEqualStrings("confirm", root.children[0].clickable_id.?);
    try std.testing.expectEqual(@as(RenderNode.Kind, .box), root.children[0].children[0].kind);
    try std.testing.expectEqual(colors.ink, root.children[0].children[0].background);
    try std.testing.expectEqual(@as(RenderNode.Kind, .text), root.children[0].children[0].children[0].children[0].kind);
    try std.testing.expectEqualStrings("Confirm", root.children[0].children[0].children[0].children[0].text.?);
}

test "row spacer takes remaining main-axis space" {
    const allocator = std.testing.allocator;

    const children = [_]Widget{
        widgets.text("A"),
        widgets.spacer(1),
        widgets.text("B"),
    };
    const row = try widgets.row(allocator, &children, 0);
    defer allocator.free(row.row.children);

    var root = try buildRenderTree(allocator, &row, .{ .max_width = 100, .max_height = 20 });
    defer destroyRenderTree(allocator, &root);

    try std.testing.expectEqual(@as(RenderNode.Kind, .row), root.kind);
    try std.testing.expectEqual(@as(f32, 100), root.rect.width);
    try std.testing.expectEqual(@as(f32, 84), root.children[1].rect.width);
    try std.testing.expectEqual(@as(f32, 92), root.children[2].rect.x);
}

test "theme selects light and dark defaults from color scheme" {
    try std.testing.expectEqual(Theme.light.color_scheme.primary, Theme.fromColorScheme("light").color_scheme.primary);
    try std.testing.expectEqual(Theme.dark.color_scheme.primary, Theme.fromColorScheme("dark").color_scheme.primary);
    try std.testing.expectEqual(Theme.light.color_scheme.primary, Theme.fromColorScheme("no-preference").color_scheme.primary);
}

test "theme widget provides ambient button styling" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const theme: Theme = .{
        .color_scheme = .light,
        .button_theme = .{
            .background = colors.black,
            .foreground = colors.white,
            .pressed_background = colors.panel,
            .padding = 4,
        },
    };
    const button_widget = try widgets.button(build_arena.allocator(), "themed", "Themed", testCallback());
    const themed = try widgets.theme(build_arena.allocator(), theme, button_widget);
    var root = try buildRenderTree(retained_allocator, &themed, .{ .max_width = 200, .max_height = 80 });
    defer destroyRenderTree(retained_allocator, &root);

    const box_node = root.children[0].children[0].children[0];
    try std.testing.expectEqual(@as(RenderNode.Kind, .theme), root.kind);
    try std.testing.expectEqual(@as(RenderNode.Kind, .box), box_node.kind);
    try std.testing.expectEqual(colors.black, box_node.background);
    try std.testing.expectEqual(@as(f32, 56), root.rect.width);
}

test "button uses ambient hover styling" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const theme: Theme = .{
        .color_scheme = .light,
        .button_theme = .{
            .background = colors.accent,
            .foreground = colors.white,
            .hover_background = colors.black,
            .hover_foreground = colors.panel,
        },
    };
    const button_widget = try widgets.button(build_arena.allocator(), "hovered", "Hover", testCallback());
    const themed = try widgets.theme(build_arena.allocator(), theme, button_widget);
    var scope: BuildScope = .{
        .allocator = build_arena.allocator(),
        .interaction = .{ .hovered_id = "hovered" },
    };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &themed, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(retained_allocator, &element);
    var root = try buildRenderTreeFromElement(retained_allocator, &element, .{ .max_width = 200, .max_height = 80 }, .fixed);
    defer destroyRenderTree(retained_allocator, &root);

    const box_node = root.children[0].children[0].children[0];
    const text_node = box_node.children[0].children[0];
    try std.testing.expectEqual(colors.black, box_node.background);
    try std.testing.expectEqual(colors.panel, text_node.foreground);
}

test "button uses ambient pressed styling" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const theme: Theme = .{
        .color_scheme = .light,
        .button_theme = .{
            .background = colors.accent,
            .pressed_background = colors.ink,
        },
    };
    const button_widget = try widgets.button(build_arena.allocator(), "pressed", "Press", testCallback());
    const themed = try widgets.theme(build_arena.allocator(), theme, button_widget);
    var scope: BuildScope = .{
        .allocator = build_arena.allocator(),
        .interaction = .{ .pressed_id = "pressed" },
    };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &themed, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(retained_allocator, &element);
    var root = try buildRenderTreeFromElement(retained_allocator, &element, .{ .max_width = 200, .max_height = 80 }, .fixed);
    defer destroyRenderTree(retained_allocator, &root);

    const box_node = root.children[0].children[0].children[0];
    try std.testing.expectEqual(colors.ink, box_node.background);
}

test "button uses ambient focused border" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const theme: Theme = .{
        .color_scheme = .light,
        .button_theme = .{
            .background = colors.accent,
            .focused_border = colors.black,
        },
    };
    const button_widget = try widgets.button(build_arena.allocator(), "focused", "Focus", testCallback());
    const themed = try widgets.theme(build_arena.allocator(), theme, button_widget);
    var scope: BuildScope = .{
        .allocator = build_arena.allocator(),
        .interaction = .{ .focused_id = "focused" },
    };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &themed, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(retained_allocator, &element);
    var root = try buildRenderTreeFromElement(retained_allocator, &element, .{ .max_width = 200, .max_height = 80 }, .fixed);
    defer destroyRenderTree(retained_allocator, &root);

    const box_node = root.children[0].children[0].children[0];
    try std.testing.expectEqual(colors.black, box_node.box_border.?);
}

test "button without action is disabled and skipped by focus traversal" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const theme: Theme = .{
        .color_scheme = .light,
        .button_theme = .{
            .disabled_background = colors.panel,
            .disabled_foreground = colors.ink,
        },
    };
    const button_widget = try widgets.button(build_arena.allocator(), "disabled", "Disabled", null);
    const themed = try widgets.theme(build_arena.allocator(), theme, button_widget);
    var root = try buildRenderTree(retained_allocator, &themed, .{ .max_width = 200, .max_height = 80 });
    defer destroyRenderTree(retained_allocator, &root);

    const box_node = root.children[0].children[0];
    try std.testing.expectEqual(@as(RenderNode.Kind, .box), box_node.kind);
    try std.testing.expectEqual(colors.panel, box_node.background);
    try std.testing.expectEqual(colors.ink, box_node.children[0].children[0].foreground);

    const targets = try collectFocusTargets(retained_allocator, &root);
    defer retained_allocator.free(targets);
    try std.testing.expectEqual(@as(usize, 0), targets.len);
}

test "action button resolves nearest ambient action" {
    const Counter = struct {
        value: usize = 0,

        fn increment(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.value += 1;
        }
    };

    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    var counter: Counter = .{};
    const button_widget = try widgets.actionButton(build_arena.allocator(), "increment", "Increment", "increment");
    const bindings = [_]Widget.ActionBinding{.{ .id = "increment", .callback = .{ .ptr = &counter, .call_fn = Counter.increment } }};
    const actions_widget = try widgets.actions(build_arena.allocator(), &bindings, button_widget);
    var scope: BuildScope = .{ .allocator = build_arena.allocator() };

    var element = try buildElementTreeScoped(retained_allocator, &scope, &actions_widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(retained_allocator, &element);
    var root = try buildRenderTreeFromElement(retained_allocator, &element, .{ .max_width = 200, .max_height = 80 }, .fixed);
    defer destroyRenderTree(retained_allocator, &root);

    const hit = hitTestClick(&root, .{ .x = 2, .y = 2 }).?;
    try hit.callback.?.call();
    try std.testing.expectEqual(@as(usize, 1), counter.value);
}

test "theme widget provides ambient text and input styling" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const children = [_]Widget{
        widgets.text("plain"),
        widgets.textInput("input", "", "placeholder"),
    };
    const column = try widgets.column(build_arena.allocator(), &children, 4);
    const themed = try widgets.theme(build_arena.allocator(), Theme.dark, column);
    var root = try buildRenderTree(retained_allocator, &themed, .{ .max_width = 200, .max_height = 120 });
    defer destroyRenderTree(retained_allocator, &root);

    const text_node = root.children[0].children[0].children[0];
    const input_node = root.children[0].children[0].children[1];
    try std.testing.expectEqual(Theme.dark.color_scheme.on_surface, text_node.foreground);
    try std.testing.expectEqual(Theme.dark.color_scheme.surface_variant, input_node.background);
    try std.testing.expectEqual(Theme.dark.color_scheme.outline, input_node.border);
    try std.testing.expectEqual(Theme.dark.input_theme.placeholder.?, input_node.placeholder_foreground);
}

test "text input derives focus from ambient focus node" {
    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const input = widgets.textInputWithFocusNode("input", .named("field-focus"), "", "placeholder");
    var scope: BuildScope = .{
        .allocator = build_arena.allocator(),
        .interaction = .{ .focused_id = "field-focus" },
    };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &input, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(retained_allocator, &element);
    var root = try buildRenderTreeFromElement(retained_allocator, &element, .{ .max_width = 200, .max_height = 80 }, .fixed);
    defer destroyRenderTree(retained_allocator, &root);

    try std.testing.expect(root.focused);
    try std.testing.expectEqualStrings("field-focus", root.focus_id.?);
    try std.testing.expectEqualStrings("field-focus", hitTestTextInput(&root, .{ .x = 1, .y = 1 }).?);
}

test "focus targets are collected in render tree order" {
    const allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(allocator);
    defer build_arena.deinit();
    const build_allocator = build_arena.allocator();

    const input = widgets.textInput("input", "", "placeholder");
    const button = try widgets.button(build_allocator, "button", "Button", testCallback());
    const children = [_]Widget{ input, button };
    const column = try widgets.column(build_allocator, &children, 4);
    var root = try buildRenderTree(allocator, &column, .{ .max_width = 200, .max_height = 120 });
    defer destroyRenderTree(allocator, &root);

    const targets = try collectFocusTargets(allocator, &root);
    defer allocator.free(targets);
    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expectEqualStrings("input", targets[0].id);
    try std.testing.expectEqual(FocusTarget.Kind.text_input, targets[0].kind);
    try std.testing.expectEqualStrings("button", targets[1].id);
    try std.testing.expectEqual(FocusTarget.Kind.clickable, targets[1].kind);
    try std.testing.expectEqual(FocusTarget.Kind.clickable, findFocusTarget(&root, "button").?.kind);
}

test "focus widget makes arbitrary subtree focusable" {
    const allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(allocator);
    defer build_arena.deinit();

    const label = widgets.text("Focusable text");
    const focus = try widgets.focus(build_arena.allocator(), .named("label-focus"), label);

    var root = try buildRenderTree(allocator, &focus, .{ .max_width = 200, .max_height = 80 });
    defer destroyRenderTree(allocator, &root);

    const targets = try collectFocusTargets(allocator, &root);
    defer allocator.free(targets);
    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqualStrings("label-focus", targets[0].id);
    try std.testing.expectEqual(FocusTarget.Kind.focus, targets[0].kind);
    try std.testing.expectEqual(FocusTarget.Kind.focus, findFocusTarget(&root, "label-focus").?.kind);
}

test "center moves descendants" {
    const allocator = std.testing.allocator;

    const label: Widget = .{ .text = .{ .value = "Run" } };
    const button: Widget = .{ .clickable = .{ .id = "centered", .child = &label, .on_click = testCallback() } };
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

test "clickable hit testing carries activation mode" {
    const label: Widget = .{ .text = .{ .value = "Press" } };
    const button: Widget = .{ .clickable = .{
        .id = "pressable",
        .child = &label,
        .on_click = testCallback(),
        .activation = .press,
    } };

    var root = try buildRenderTree(std.testing.allocator, &button, .{ .max_width = 100, .max_height = 80 });
    defer destroyRenderTree(std.testing.allocator, &root);

    const hit = hitTestClick(&root, .{ .x = 2, .y = 2 }).?;
    try std.testing.expectEqual(Widget.ClickActivation.press, hit.activation);
}

test "clickable hit testing carries gesture callbacks" {
    const label: Widget = .{ .text = .{ .value = "Gesture" } };
    const button: Widget = .{ .clickable = .{
        .id = "gesture",
        .child = &label,
        .on_tap_down = testCallback(),
        .on_tap_up = testCallback(),
        .on_tap_cancel = testCallback(),
    } };

    var root = try buildRenderTree(std.testing.allocator, &button, .{ .max_width = 100, .max_height = 80 });
    defer destroyRenderTree(std.testing.allocator, &root);

    const hit = hitTestClick(&root, .{ .x = 2, .y = 2 }).?;
    try std.testing.expect(hit.tap_down != null);
    try std.testing.expect(hit.tap_up != null);
    try std.testing.expect(hit.tap_cancel != null);
}

test "clickable without callback is inert" {
    const label: Widget = .{ .text = .{ .value = "Inert" } };
    const clickable: Widget = .{ .clickable = .{ .id = "inert", .child = &label } };

    var root = try buildRenderTree(std.testing.allocator, &clickable, .{ .max_width = 100, .max_height = 80 });
    defer destroyRenderTree(std.testing.allocator, &root);

    try std.testing.expectEqual(@as(?ClickHit, null), hitTestClick(&root, .{ .x = 2, .y = 2 }));
    const targets = try collectFocusTargets(std.testing.allocator, &root);
    defer std.testing.allocator.free(targets);
    try std.testing.expectEqual(@as(usize, 0), targets.len);
}

test "shortcuts invoke ambient actions" {
    const Counter = struct {
        value: usize = 0,

        fn increment(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.value += 1;
        }
    };

    const allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(allocator);
    defer build_arena.deinit();

    var counter: Counter = .{};
    const child = widgets.text("Shortcut child");
    const shortcut_bindings = [_]Widget.ShortcutBinding{.{ .key = .enter, .intent = .action("increment") }};
    const action_bindings = [_]Widget.ActionBinding{.{ .id = "increment", .callback = .{ .ptr = &counter, .call_fn = Counter.increment } }};
    const shortcuts_widget = try widgets.shortcuts(build_arena.allocator(), &shortcut_bindings, child);
    const actions_widget = try widgets.actions(build_arena.allocator(), &action_bindings, shortcuts_widget);

    var element = try buildElementTree(allocator, &actions_widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(allocator, &element);

    const callback = findShortcutAction(&element, .enter).?;
    try callback.call();
    try std.testing.expectEqual(@as(usize, 1), counter.value);
    try std.testing.expectEqual(@as(?Widget.Callback, null), findShortcutAction(&element, .space));
}

test "button and shortcut can share an intent" {
    const Counter = struct {
        value: usize = 0,

        fn increment(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.value += 1;
        }
    };

    const allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(allocator);
    defer build_arena.deinit();

    var counter: Counter = .{};
    const intent = Intent.action("increment");
    const button = try widgets.intentButton(build_arena.allocator(), "increment-button", "Increment", intent);
    const shortcut_bindings = [_]Widget.ShortcutBinding{.{ .key = .enter, .intent = intent }};
    const action_bindings = [_]Widget.ActionBinding{.{ .id = "increment", .callback = .{ .ptr = &counter, .call_fn = Counter.increment } }};
    const root_widget = try widgets.actions(
        build_arena.allocator(),
        &action_bindings,
        try widgets.shortcuts(build_arena.allocator(), &shortcut_bindings, button),
    );

    var element = try buildElementTree(allocator, &root_widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(allocator, &element);
    var root = try buildRenderTreeFromElement(allocator, &element, .{ .max_width = 200, .max_height = 80 }, .fixed);
    defer destroyRenderTree(allocator, &root);

    try findShortcutAction(&element, .enter).?.call();
    const hit = hitTestClick(&root, .{ .x = 2, .y = 2 }).?;
    try hit.callback.?.call();
    try std.testing.expectEqual(@as(usize, 2), counter.value);
}

test "focused shortcut resolution prefers nearest shortcut and action scopes" {
    const Counters = struct {
        global: usize = 0,
        local: usize = 0,

        fn incrementGlobal(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.global += 1;
        }

        fn incrementLocal(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.local += 1;
        }
    };

    const allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(allocator);
    defer build_arena.deinit();

    var counters: Counters = .{};
    const global_button = try widgets.actionButton(build_arena.allocator(), "global-button", "Global", "activate");
    const local_button = try widgets.actionButton(build_arena.allocator(), "local-button", "Local", "activate");
    const local_actions = [_]Widget.ActionBinding{.{ .id = "activate", .callback = .{ .ptr = &counters, .call_fn = Counters.incrementLocal } }};
    const local_shortcuts = [_]Widget.ShortcutBinding{.{ .key = .space, .intent = .action("activate") }};
    const local_subtree = try widgets.actions(
        build_arena.allocator(),
        &local_actions,
        try widgets.shortcuts(build_arena.allocator(), &local_shortcuts, local_button),
    );
    const children = [_]Widget{ global_button, local_subtree };
    const column = try widgets.column(build_arena.allocator(), &children, 4);
    const global_actions = [_]Widget.ActionBinding{.{ .id = "activate", .callback = .{ .ptr = &counters, .call_fn = Counters.incrementGlobal } }};
    const global_shortcuts = [_]Widget.ShortcutBinding{.{ .key = .space, .intent = .action("activate") }};
    const root_widget = try widgets.actions(
        build_arena.allocator(),
        &global_actions,
        try widgets.shortcuts(build_arena.allocator(), &global_shortcuts, column),
    );

    var element = try buildElementTree(allocator, &root_widget, .{ .max_width = 200, .max_height = 120 });
    defer destroyElementTree(allocator, &element);

    try findFocusedShortcutAction(&element, .space, "local-button").?.call();
    try std.testing.expectEqual(@as(usize, 0), counters.global);
    try std.testing.expectEqual(@as(usize, 1), counters.local);

    try findFocusedShortcutAction(&element, .space, "global-button").?.call();
    try std.testing.expectEqual(@as(usize, 1), counters.global);
    try std.testing.expectEqual(@as(usize, 1), counters.local);
}

test "component widget builds into the render tree" {
    const LabelComponent = struct {
        value: []const u8,

        const vtable: Widget.Component.VTable = .{ .build = build };

        fn widget(self: *const @This()) Widget {
            return .{ .component = .{ .ptr = self, .vtable = &vtable } };
        }

        fn build(ptr: *const anyopaque, scope: *BuildScope, context: Widget.BuildContext) !Widget {
            _ = scope;
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

test "element tree retains cloned callbacks beyond build scope" {
    const CallbackState = struct {
        calls: *usize,
        clones: *usize,
        destroys: *usize,

        fn callback(self: *@This()) Widget.Callback {
            return .{
                .ptr = self,
                .call_fn = call,
                .clone_fn = clone,
                .destroy_fn = destroy,
            };
        }

        fn call(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls.* += 1;
        }

        fn clone(allocator: std.mem.Allocator, ptr: *anyopaque) !*anyopaque {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.clones.* += 1;
            const result = try allocator.create(@This());
            result.* = self.*;
            return result;
        }

        fn destroy(allocator: std.mem.Allocator, ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.destroys.* += 1;
            allocator.destroy(self);
        }
    };

    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    var calls: usize = 0;
    var clones: usize = 0;
    var destroys: usize = 0;
    const build_allocator = build_arena.allocator();
    const state = try build_allocator.create(CallbackState);
    state.* = .{ .calls = &calls, .clones = &clones, .destroys = &destroys };
    const label_value = try build_allocator.dupe(u8, "arena label");
    const label: Widget = .{ .text = .{ .value = label_value } };
    const button: Widget = .{ .clickable = .{
        .id = try build_allocator.dupe(u8, "arena-button"),
        .child = &label,
        .on_click = state.callback(),
    } };
    var scope: BuildScope = .{ .allocator = build_allocator };

    var element = try buildElementTreeScoped(retained_allocator, &scope, &button, .{ .max_width = 100, .max_height = 80 });
    try std.testing.expectEqual(@as(usize, 1), clones);
    try std.testing.expectEqual(@as(usize, 0), destroys);

    try std.testing.expect(build_arena.reset(.free_all));
    try element.widget.clickable.on_click.?.call();
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqualStrings("arena-button", element.widget.clickable.id);
    try std.testing.expectEqualStrings("arena label", element.children[0].widget.text.value);

    destroyElementTree(retained_allocator, &element);
    try std.testing.expectEqual(@as(usize, 1), destroys);
}

test "button composed clickable borrows retained action callback" {
    const CallbackState = struct {
        calls: *usize,
        clones: *usize,
        destroys: *usize,

        fn callback(self: *@This()) Widget.Callback {
            return .{
                .ptr = self,
                .call_fn = call,
                .clone_fn = clone,
                .destroy_fn = destroy,
            };
        }

        fn call(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls.* += 1;
        }

        fn clone(allocator: std.mem.Allocator, ptr: *anyopaque) !*anyopaque {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.clones.* += 1;
            const result = try allocator.create(@This());
            result.* = self.*;
            return result;
        }

        fn destroy(allocator: std.mem.Allocator, ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.destroys.* += 1;
            allocator.destroy(self);
        }
    };

    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    var calls: usize = 0;
    var clones: usize = 0;
    var destroys: usize = 0;
    const state = try build_arena.allocator().create(CallbackState);
    state.* = .{ .calls = &calls, .clones = &clones, .destroys = &destroys };
    const button = try widgets.button(build_arena.allocator(), "action", "Action", state.callback());
    var scope: BuildScope = .{ .allocator = build_arena.allocator() };

    var element = try buildElementTreeScoped(retained_allocator, &scope, &button, .{ .max_width = 120, .max_height = 80 });
    try std.testing.expectEqual(@as(usize, 1), clones);
    try std.testing.expectEqual(element.widget.button.on_pressed.?.ptr, element.children[0].widget.clickable.on_click.?.ptr);

    try std.testing.expect(build_arena.reset(.free_all));
    try element.children[0].widget.clickable.on_click.?.call();
    try std.testing.expectEqual(@as(usize, 1), calls);

    destroyElementTree(retained_allocator, &element);
    try std.testing.expectEqual(@as(usize, 1), destroys);
}

test "element tree retains cloned render objects beyond build scope" {
    const RenderState = struct {
        clones: *usize,
        destroys: *usize,

        const vtable: Widget.RenderObject.VTable = .{
            .layout = layout,
            .paint = paintObject,
        };

        fn widget(self: *const @This()) Widget {
            return .{ .render_object = .{
                .ptr = self,
                .vtable = &vtable,
                .clone_fn = clone,
                .destroy_fn = destroy,
            } };
        }

        fn layout(ptr: *const anyopaque, context: Widget.RenderObject.LayoutContext) !Size {
            _ = ptr;
            return context.constraints.clamp(.{ .width = 24, .height = 12 });
        }

        fn paintObject(ptr: *const anyopaque, context: Widget.RenderObject.PaintContext) !void {
            _ = ptr;
            try context.display_list.fillRect(context.allocator, context.rect, colors.accent);
        }

        fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.clones.* += 1;
            const result = try allocator.create(@This());
            result.* = self.*;
            return result;
        }

        fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.destroys.* += 1;
            allocator.destroy(@constCast(self));
        }
    };

    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    var clones: usize = 0;
    var destroys: usize = 0;
    const state = try build_arena.allocator().create(RenderState);
    state.* = .{ .clones = &clones, .destroys = &destroys };
    const widget = state.widget();
    var scope: BuildScope = .{ .allocator = build_arena.allocator() };

    var element = try buildElementTreeScoped(retained_allocator, &scope, &widget, .{ .max_width = 100, .max_height = 80 });
    try std.testing.expectEqual(@as(usize, 1), clones);
    try std.testing.expectEqual(@as(usize, 0), destroys);

    try std.testing.expect(build_arena.reset(.free_all));
    var root = try layoutElement(retained_allocator, &element, .{ .max_width = 100, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);
    defer destroyRenderTree(retained_allocator, &root);
    try std.testing.expectEqual(@as(RenderNode.Kind, .render_object), root.kind);
    try std.testing.expectEqual(@as(f32, 24), root.rect.width);

    var display_list: DisplayList = .{};
    defer display_list.deinit(retained_allocator);
    try paint(retained_allocator, &root, &display_list);
    try std.testing.expectEqual(@as(usize, 1), display_list.commands.items.len);

    destroyElementTree(retained_allocator, &element);
    try std.testing.expectEqual(@as(usize, 1), destroys);
}

test "element tree retains cloned stateful widgets beyond build scope" {
    const StatefulSource = struct {
        clones: *usize,
        destroys: *usize,
        states_created: *usize,
        states_destroyed: *usize,

        const State = struct {};
        const vtable: Widget.Stateful.VTable = .{
            .create_state = createState,
            .update = update,
            .build = build,
            .destroy_state = destroyState,
        };

        fn widget(self: *const @This()) Widget {
            return .{ .stateful = .{
                .ptr = self,
                .vtable = &vtable,
                .clone_fn = clone,
                .destroy_fn = destroy,
            } };
        }

        fn createState(ptr: *const anyopaque, allocator: std.mem.Allocator) !*anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.states_created.* += 1;
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

        fn build(ptr: *const anyopaque, state: *anyopaque, scope: *BuildScope, context: Widget.BuildContext) !Widget {
            _ = ptr;
            _ = state;
            _ = context;
            const value = try std.fmt.allocPrint(scope.allocator, "stateful survives", .{});
            return .{ .text = .{ .value = value } };
        }

        fn destroyState(ptr: *const anyopaque, state_ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.states_destroyed.* += 1;
            const state: *State = @ptrCast(@alignCast(state_ptr));
            allocator.destroy(state);
        }

        fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.clones.* += 1;
            const result = try allocator.create(@This());
            result.* = self.*;
            return result;
        }

        fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.destroys.* += 1;
            allocator.destroy(@constCast(self));
        }
    };

    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    var clones: usize = 0;
    var destroys: usize = 0;
    var states_created: usize = 0;
    var states_destroyed: usize = 0;
    const source = try build_arena.allocator().create(StatefulSource);
    source.* = .{
        .clones = &clones,
        .destroys = &destroys,
        .states_created = &states_created,
        .states_destroyed = &states_destroyed,
    };
    const widget = source.widget();
    var scope: BuildScope = .{ .allocator = build_arena.allocator() };

    var element = try buildElementTreeScoped(retained_allocator, &scope, &widget, .{ .max_width = 100, .max_height = 80 });
    try std.testing.expectEqual(@as(usize, 1), clones);
    try std.testing.expectEqual(@as(usize, 1), states_created);

    try std.testing.expect(build_arena.reset(.free_all));
    try std.testing.expectEqualStrings("stateful survives", element.children[0].widget.text.value);

    destroyElementTree(retained_allocator, &element);
    try std.testing.expectEqual(@as(usize, 1), states_destroyed);
    try std.testing.expectEqual(@as(usize, 1), destroys);
}

test "element tree retains cloned custom elements beyond build scope" {
    const CustomSource = struct {
        clones: *usize,
        destroys: *usize,

        const vtable: Widget.CustomElement.VTable = .{ .build = build };

        fn widget(self: *const @This()) Widget {
            return .{ .element = .{
                .ptr = self,
                .vtable = &vtable,
                .clone_fn = clone,
                .destroy_fn = destroy,
            } };
        }

        fn build(ptr: *const anyopaque, allocator: std.mem.Allocator, scope: *BuildScope, context: Widget.BuildContext) !Element {
            _ = ptr;
            const value = try std.fmt.allocPrint(scope.allocator, "custom element {d}", .{@as(u32, 7)});
            const label: Widget = .{ .text = .{ .value = value, .color = colors.accent } };
            return buildElementTreeScoped(allocator, scope, &label, context.constraints);
        }

        fn clone(allocator: std.mem.Allocator, ptr: *const anyopaque) !*const anyopaque {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.clones.* += 1;
            const result = try allocator.create(@This());
            result.* = self.*;
            return result;
        }

        fn destroy(allocator: std.mem.Allocator, ptr: *const anyopaque) void {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            self.destroys.* += 1;
            allocator.destroy(@constCast(self));
        }
    };

    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    var clones: usize = 0;
    var destroys: usize = 0;
    const source = try build_arena.allocator().create(CustomSource);
    source.* = .{ .clones = &clones, .destroys = &destroys };
    const widget = source.widget();
    var scope: BuildScope = .{ .allocator = build_arena.allocator() };

    var element = try buildElementTreeScoped(retained_allocator, &scope, &widget, .{ .max_width = 100, .max_height = 80 });
    try std.testing.expectEqual(@as(usize, 1), clones);
    try std.testing.expectEqual(@as(usize, 0), destroys);

    try std.testing.expect(build_arena.reset(.free_all));
    try std.testing.expectEqualStrings("custom element 7", element.children[0].widget.text.value);

    destroyElementTree(retained_allocator, &element);
    try std.testing.expectEqual(@as(usize, 1), destroys);
}

test "component build products are retained outside the build arena" {
    const ArenaComponent = struct {
        value: usize,

        const vtable: Widget.Component.VTable = .{ .build = build };

        fn widget(self: *const @This()) Widget {
            return .{ .component = .{ .ptr = self, .vtable = &vtable } };
        }

        fn build(ptr: *const anyopaque, scope: *BuildScope, context: Widget.BuildContext) !Widget {
            _ = context;
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            const value = try std.fmt.allocPrint(scope.allocator, "component {d}", .{self.value});
            return .{ .text = .{ .value = value } };
        }
    };

    const retained_allocator = std.testing.allocator;
    var build_arena = std.heap.ArenaAllocator.init(retained_allocator);
    defer build_arena.deinit();

    const component: ArenaComponent = .{ .value = 42 };
    const widget = component.widget();
    var scope: BuildScope = .{ .allocator = build_arena.allocator() };
    var element = try buildElementTreeScoped(retained_allocator, &scope, &widget, .{ .max_width = 200, .max_height = 80 });
    defer destroyElementTree(retained_allocator, &element);

    try std.testing.expect(build_arena.reset(.free_all));
    try std.testing.expectEqualStrings("component 42", element.children[0].widget.text.value);

    var root = try layoutElement(retained_allocator, &element, .{ .max_width = 200, .max_height = 80 }, .{ .x = 0, .y = 0 }, .fixed);
    defer destroyRenderTree(retained_allocator, &root);
    try std.testing.expectEqual(@as(RenderNode.Kind, .component), root.kind);
    try std.testing.expectEqual(@as(RenderNode.Kind, .text), root.children[0].kind);
    try std.testing.expectEqualStrings("component 42", root.children[0].text.?);
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

        fn build(ptr: *const anyopaque, state_ptr: *anyopaque, scope: *BuildScope, context: Widget.BuildContext) !Widget {
            _ = scope;
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

        fn build(ptr: *const anyopaque, state: *anyopaque, scope: *BuildScope, context: Widget.BuildContext) !Widget {
            _ = ptr;
            _ = state;
            _ = scope;
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

        fn build(ptr: *const anyopaque, allocator: std.mem.Allocator, scope: *BuildScope, context: Widget.BuildContext) !Element {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            const label: Widget = .{ .text = .{ .value = self.value, .color = colors.accent } };
            return buildElementTreeScoped(allocator, scope, &label, context.constraints);
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
