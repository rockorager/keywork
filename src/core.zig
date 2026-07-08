//! Core Keywork framework types, element/render trees, layout, painting, and hit testing.

const std = @import("std");
const z2d = @import("z2d");

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

    pub const slate1: Color = Color.argb(0xff, 0xfc, 0xfc, 0xfd);
    pub const slate2: Color = Color.argb(0xff, 0xf9, 0xf9, 0xfb);
    pub const slate3: Color = Color.argb(0xff, 0xf0, 0xf0, 0xf3);
    pub const slate7: Color = Color.argb(0xff, 0xcd, 0xce, 0xd6);
    pub const slate11: Color = Color.argb(0xff, 0x60, 0x64, 0x6c);
    pub const slate12: Color = Color.argb(0xff, 0x1c, 0x20, 0x24);
    pub const slate_a3: Color = Color.argb(0x0f, 0x00, 0x00, 0x33);
    pub const slate_a4: Color = Color.argb(0x17, 0x00, 0x00, 0x2d);

    pub const slate_dark1: Color = Color.argb(0xff, 0x11, 0x11, 0x13);
    pub const slate_dark2: Color = Color.argb(0xff, 0x18, 0x19, 0x1b);
    pub const slate_dark3: Color = Color.argb(0xff, 0x21, 0x22, 0x25);
    pub const slate_dark7: Color = Color.argb(0xff, 0x43, 0x48, 0x4e);
    pub const slate_dark11: Color = Color.argb(0xff, 0xb0, 0xb4, 0xba);
    pub const slate_dark12: Color = Color.argb(0xff, 0xed, 0xee, 0xf0);
    pub const slate_dark_a3: Color = Color.argb(0x14, 0xdd, 0xea, 0xf8);
    pub const slate_dark_a4: Color = Color.argb(0x1d, 0xd3, 0xed, 0xf8);

    pub const blue9: Color = Color.argb(0xff, 0x00, 0x90, 0xff);
    pub const blue10: Color = Color.argb(0xff, 0x05, 0x88, 0xf0);
    pub const blue11: Color = Color.argb(0xff, 0x0d, 0x74, 0xce);
    pub const blue_dark10: Color = Color.argb(0xff, 0x3b, 0x9e, 0xff);
    pub const blue_dark11: Color = Color.argb(0xff, 0x70, 0xb8, 0xff);
    pub const red9: Color = Color.argb(0xff, 0xe5, 0x48, 0x4d);

    pub const ink: Color = slate12;
    pub const panel: Color = slate2;
    pub const accent: Color = blue9;
};

pub const Brightness = enum {
    light,
    dark,
};

pub const ColorScheme = struct {
    brightness: Brightness,
    primary: Color,
    on_primary: Color,
    primary_container: Color,
    on_primary_container: Color,
    surface: Color,
    on_surface: Color,
    on_surface_variant: Color,
    surface_container_low: Color,
    surface_container: Color,
    surface_container_high: Color,
    error_color: Color,
    on_error: Color,
    error_container: Color,
    on_error_container: Color,
    outline: Color,
    outline_variant: Color,

    pub const light: ColorScheme = .{
        .brightness = .light,
        .primary = colors.accent,
        .on_primary = colors.white,
        .primary_container = colors.blue10,
        .on_primary_container = colors.white,
        .surface = colors.slate1,
        .on_surface = colors.ink,
        .on_surface_variant = colors.slate11,
        .surface_container_low = colors.slate_a3,
        .surface_container = colors.slate2,
        .surface_container_high = colors.slate_a4,
        .error_color = colors.red9,
        .on_error = colors.white,
        .error_container = colors.red9,
        .on_error_container = colors.white,
        .outline = colors.slate7,
        .outline_variant = colors.slate7,
    };

    pub const dark: ColorScheme = .{
        .brightness = .dark,
        .primary = colors.blue9,
        .on_primary = colors.black,
        .primary_container = colors.blue_dark10,
        .on_primary_container = colors.black,
        .surface = colors.slate_dark2,
        .on_surface = colors.slate_dark12,
        .on_surface_variant = colors.slate_dark11,
        .surface_container_low = colors.slate_dark_a3,
        .surface_container = colors.slate_dark2,
        .surface_container_high = colors.slate_dark_a4,
        .error_color = colors.red9,
        .on_error = colors.black,
        .error_container = colors.red9,
        .on_error_container = colors.black,
        .outline = colors.slate_dark7,
        .outline_variant = colors.slate_dark7,
    };
};

pub const TextStyle = struct {
    color: ?Color = null,
    font_size: ?f32 = null,
};

pub const ResolvedTextStyle = struct {
    color: Color,
    font_size: f32,
};

pub const TextRole = enum {
    body,
    label,
    title,
};

pub const TextTheme = struct {
    body: TextStyle = .{ .font_size = 16 },
    label: TextStyle = .{ .font_size = 14 },
    title: TextStyle = .{ .font_size = 20 },
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
    padding_x: f32 = 12,
    padding_y: f32 = 8,
    radius: f32 = 8,
};

pub const InputTheme = struct {
    background: ?Color = null,
    foreground: ?Color = null,
    placeholder: ?Color = null,
    border: ?Color = null,
    focused_border: ?Color = null,
    padding_x: f32 = 12,
    padding_y: f32 = 8,
    radius: f32 = 8,
};

pub const Theme = struct {
    color_scheme: ColorScheme,
    text_theme: TextTheme = .{},
    button_theme: ButtonTheme = .{},
    input_theme: InputTheme = .{},

    pub const light: Theme = .{
        .color_scheme = .light,
    };
    pub const dark: Theme = .{
        .color_scheme = .dark,
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
    output: Output = .compositor_default,

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

    pub const Output = enum {
        compositor_default,
        all,
    };
};

pub const ShortcutKey = enum {
    enter,
    space,
    backspace,
    escape,
    up,
    down,
};

pub const HandlerId = u64;
pub const DocumentId = u64;
pub const ResourceId = u64;

pub const HandlerRef = struct {
    document: DocumentId,
    handler: HandlerId,
};

pub const EventPayload = union(enum) {
    none,
    bool: bool,
    text: []const u8,
};

pub const HandlerSink = struct {
    ptr: *anyopaque,
    emit_fn: *const fn (ptr: *anyopaque, handler: HandlerRef, payload: EventPayload) anyerror!void,

    pub fn emit(self: HandlerSink, handler: HandlerRef, payload: EventPayload) !void {
        try self.emit_fn(self.ptr, handler, payload);
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

    pub fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.x + self.width, other.x + other.width);
        const y1 = @min(self.y + self.height, other.y + other.height);
        return .{ .x = x0, .y = y0, .width = @max(0, x1 - x0), .height = @max(0, y1 - y0) };
    }

    pub fn isEmpty(self: Rect) bool {
        return self.width <= 0 or self.height <= 0;
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
    container: Container,
    filled_button: FilledButton,
    gesture_detector: GestureDetector,
    focus: Focus,
    focus_scope: FocusScope,
    single_child_scroll_view: SingleChildScrollView,
    text_field: TextField,
    row: Children,
    column: Children,
    spacer: Spacer,
    flexible: Flexible,
    sized_box: SizedBox,
    padding: Padding,
    center: Child,
    shortcuts: Shortcuts,
    default_text_style: DefaultTextStyle,
    image: Image,
    icon: Icon,

    pub fn alloc(allocator: std.mem.Allocator, widget: Widget) !*Widget {
        const result = try allocator.create(Widget);
        result.* = widget;
        return result;
    }

    pub fn allocSlice(allocator: std.mem.Allocator, items: []const Widget) ![]Widget {
        return allocator.dupe(Widget, items);
    }

    pub const Text = struct {
        key: ?[]const u8 = null,
        value: []const u8,
        color: ?Color = null,
        font_size: ?f32 = null,
        role: TextRole = .body,
    };

    pub const Container = struct {
        key: ?[]const u8 = null,
        child: *const Widget,
        background: Color = colors.transparent,
        border: ?Color = null,
        border_width: f32 = 1,
        radius: f32 = 0,
        min_width: f32 = 0,
        min_height: f32 = 0,
        horizontal_align: Alignment = .start,
        vertical_align: Alignment = .start,
    };

    /// A semantic, theme-aware button. Text and untinted icons inherit the
    /// button foreground; default, hover, pressed, focused, and disabled
    /// presentation is resolved from the active Theme inside libkeywork.
    pub const FilledButton = struct {
        key: ?[]const u8 = null,
        id: []const u8,
        /// Null disables activation, focus traversal, and pointer hover while
        /// retaining the button's themed disabled presentation.
        handler: ?HandlerId = null,
        child: *const Widget,
        activation: ClickActivation = .press,
    };

    pub const GestureDetector = struct {
        key: ?[]const u8 = null,
        id: []const u8,
        handler: HandlerId,
        child: *const Widget,
        activation: ClickActivation = .release,
        hover_style: ?GestureDetectorStyle = null,
    };

    pub const GestureDetectorStyle = struct {
        background: ?Color = null,
        base_background: ?Color = null,
    };

    pub const ClickActivation = enum {
        release,
        press,
    };

    pub const Focus = struct {
        key: ?[]const u8 = null,
        node: FocusNode,
        child: *const Widget,
        autofocus: bool = false,
        skip_traversal: bool = false,
        can_request_focus: bool = true,
        on_focus_change: ?HandlerId = null,
    };

    pub const FocusScope = struct {
        key: ?[]const u8 = null,
        id: []const u8,
        child: *const Widget,
        modal: bool = false,
    };

    pub const ShortcutBinding = struct {
        key: ShortcutKey,
        handler: HandlerId,
    };

    pub const Shortcuts = struct {
        key: ?[]const u8 = null,
        bindings: []const ShortcutBinding,
        child: *const Widget,
    };

    /// A scrollable viewport: the child is laid out unbounded along the
    /// scrollable axes, clipped to the viewport, and offset by the
    /// element-owned scroll position. Scrollbar thumbs are painted for
    /// axes with overflowing content.
    pub const SingleChildScrollView = struct {
        key: ?[]const u8 = null,
        id: []const u8,
        child: *const Widget,
        axes: ScrollAxes = .vertical,
    };

    pub const ScrollAxes = enum {
        vertical,
        horizontal,
        both,

        pub fn horizontalUnbounded(self: ScrollAxes) bool {
            return self != .vertical;
        }

        pub fn verticalUnbounded(self: ScrollAxes) bool {
            return self != .horizontal;
        }
    };

    pub const TextField = struct {
        key: ?[]const u8 = null,
        id: []const u8,
        focus_node: FocusNode,
        /// Initial text only: after the element is created, its editing
        /// state owns the text.
        value: []const u8,
        placeholder: []const u8,
        on_change: ?HandlerId = null,
        foreground: Color = colors.ink,
        background: Color = colors.white,
        border: Color = colors.ink,
        focused_border: Color = colors.accent,
        placeholder_foreground: Color = Color.argb(0xff, 0x77, 0x77, 0x7d),
        padding_x: f32 = 12,
        padding_y: f32 = 8,
        radius: f32 = 8,
        autofocus: bool = false,
    };

    pub const Children = struct {
        key: ?[]const u8 = null,
        children: []const Widget,
        gap: f32 = 0,
        cross_align: CrossAxisAlignment = .start,
        main_align: MainAxisAlignment = .start,
    };

    pub const CrossAxisAlignment = enum {
        start,
        center,
        end,
        stretch,
    };

    pub const MainAxisAlignment = enum {
        start,
        center,
        end,
        space_between,
        space_around,
        space_evenly,
    };

    /// A flex child of a row or column: after non-flex children take
    /// their intrinsic size, the remaining main-axis space is divided
    /// between flexible children in proportion to their flex factors.
    pub const Flexible = struct {
        key: ?[]const u8 = null,
        child: *const Widget,
        flex: f32 = 1,
        /// tight forces the child to fill its share (Flutter's Expanded);
        /// loose lets it be smaller.
        fit: FlexFit = .tight,
    };

    pub const FlexFit = enum { tight, loose };

    pub const Alignment = enum {
        start,
        center,
        end,
    };

    pub const SizedBox = struct {
        key: ?[]const u8 = null,
        child: *const Widget,
        width: ?f32 = null,
        height: ?f32 = null,
        min_width: f32 = 0,
        min_height: f32 = 0,
        max_width: ?f32 = null,
        max_height: ?f32 = null,
    };

    pub const Spacer = struct {
        key: ?[]const u8 = null,
        flex: f32 = 1,
    };

    pub const Padding = struct {
        key: ?[]const u8 = null,
        insets: EdgeInsets,
        child: *const Widget,
    };

    pub const Child = struct {
        key: ?[]const u8 = null,
        child: *const Widget,
    };

    pub const DefaultTextStyle = struct {
        key: ?[]const u8 = null,
        style: TextStyle,
        child: *const Widget,
    };

    pub const Image = struct {
        key: ?[]const u8 = null,
        resource: ResourceId,
        width: ?f32 = null,
        height: ?f32 = null,
        tint: ?Color = null,
    };

    pub const Icon = struct {
        key: ?[]const u8 = null,
        name: []const u8,
        size: f32,
        color: ?Color = null,
    };
};

pub const BuildScope = struct {
    document_id: DocumentId = 0,
    theme: Theme = .default,
    default_text_style: TextStyle = .{},
    default_icon_color: ?Color = null,
    interaction: InteractionState = .{},
    render_factory: ?RenderFactory = null,
};

pub const widgets = struct {
    pub fn text(value: []const u8) Widget {
        return .{ .text = .{ .value = value } };
    }

    pub fn coloredText(value: []const u8, color: Color) Widget {
        return .{ .text = .{ .value = value, .color = color } };
    }

    pub fn container(allocator: std.mem.Allocator, child: Widget, background: Color) !Widget {
        return .{ .container = .{ .child = try Widget.alloc(allocator, child), .background = background } };
    }

    pub fn box(allocator: std.mem.Allocator, child: Widget, background: Color) !Widget {
        return container(allocator, child, background);
    }

    pub fn gestureDetector(allocator: std.mem.Allocator, id: []const u8, handler: HandlerId, child: Widget) !Widget {
        return .{ .gesture_detector = .{ .id = id, .handler = handler, .child = try Widget.alloc(allocator, child) } };
    }

    pub fn clickable(allocator: std.mem.Allocator, id: []const u8, handler: HandlerId, child: Widget) !Widget {
        return gestureDetector(allocator, id, handler, child);
    }

    pub fn focus(allocator: std.mem.Allocator, node: FocusNode, child: Widget) !Widget {
        return focusWithOptions(allocator, node, child, .{});
    }

    pub const FocusOptions = struct {
        autofocus: bool = false,
        skip_traversal: bool = false,
        can_request_focus: bool = true,
        on_focus_change: ?HandlerId = null,
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

    pub fn focusScope(allocator: std.mem.Allocator, id: []const u8, child: Widget, modal: bool) !Widget {
        return .{ .focus_scope = .{ .id = id, .child = try Widget.alloc(allocator, child), .modal = modal } };
    }

    pub fn singleChildScrollView(allocator: std.mem.Allocator, id: []const u8, child: Widget) !Widget {
        return .{ .single_child_scroll_view = .{ .id = id, .child = try Widget.alloc(allocator, child) } };
    }

    pub fn scroll(allocator: std.mem.Allocator, id: []const u8, child: Widget) !Widget {
        return singleChildScrollView(allocator, id, child);
    }

    pub fn defaultTextStyle(allocator: std.mem.Allocator, style: TextStyle, child: Widget) !Widget {
        return .{ .default_text_style = .{ .style = style, .child = try Widget.alloc(allocator, child) } };
    }

    pub const TextFieldOptions = struct {
        focus_node: ?FocusNode = null,
        on_change: ?HandlerId = null,
        foreground: Color = colors.ink,
        background: Color = colors.white,
        border: Color = colors.ink,
        focused_border: Color = colors.accent,
        placeholder_foreground: Color = Color.argb(0xff, 0x77, 0x77, 0x7d),
        padding_x: f32 = 12,
        padding_y: f32 = 8,
        radius: f32 = 8,
        autofocus: bool = false,
    };

    pub const TextInputOptions = TextFieldOptions;

    pub fn textField(id: []const u8, value: []const u8, placeholder: []const u8, options: TextFieldOptions) Widget {
        return .{ .text_field = .{
            .id = id,
            .focus_node = options.focus_node orelse .named(id),
            .value = value,
            .placeholder = placeholder,
            .on_change = options.on_change,
            .foreground = options.foreground,
            .background = options.background,
            .border = options.border,
            .focused_border = options.focused_border,
            .placeholder_foreground = options.placeholder_foreground,
            .padding_x = options.padding_x,
            .padding_y = options.padding_y,
            .radius = options.radius,
            .autofocus = options.autofocus,
        } };
    }

    pub fn textInput(id: []const u8, value: []const u8, placeholder: []const u8, options: TextInputOptions) Widget {
        return textField(id, value, placeholder, options);
    }

    pub const LinearOptions = struct {
        gap: f32 = 0,
        cross_align: Widget.CrossAxisAlignment = .start,
        main_align: Widget.MainAxisAlignment = .start,
    };

    pub fn expanded(allocator: std.mem.Allocator, child: Widget) !Widget {
        return .{ .flexible = .{ .child = try Widget.alloc(allocator, child), .fit = .tight } };
    }

    pub fn flexible(allocator: std.mem.Allocator, child: Widget, flex: f32) !Widget {
        return .{ .flexible = .{ .child = try Widget.alloc(allocator, child), .flex = flex, .fit = .loose } };
    }

    pub fn row(allocator: std.mem.Allocator, children: []const Widget, options: LinearOptions) !Widget {
        return .{ .row = .{
            .children = try Widget.allocSlice(allocator, children),
            .gap = options.gap,
            .cross_align = options.cross_align,
            .main_align = options.main_align,
        } };
    }

    pub fn column(allocator: std.mem.Allocator, children: []const Widget, options: LinearOptions) !Widget {
        return .{ .column = .{
            .children = try Widget.allocSlice(allocator, children),
            .gap = options.gap,
            .cross_align = options.cross_align,
            .main_align = options.main_align,
        } };
    }

    pub fn spacer(flex: f32) Widget {
        return .{ .spacer = .{ .flex = @max(0, flex) } };
    }

    pub fn sizedBox(allocator: std.mem.Allocator, child: Widget, width: ?f32, height: ?f32) !Widget {
        return .{ .sized_box = .{ .child = try Widget.alloc(allocator, child), .width = width, .height = height } };
    }

    pub fn sized(allocator: std.mem.Allocator, child: Widget, width: ?f32, height: ?f32) !Widget {
        return sizedBox(allocator, child, width, height);
    }

    pub fn padding(allocator: std.mem.Allocator, insets: EdgeInsets, child: Widget) !Widget {
        return .{ .padding = .{ .insets = insets, .child = try Widget.alloc(allocator, child) } };
    }

    pub fn center(allocator: std.mem.Allocator, child: Widget) !Widget {
        return .{ .center = .{ .child = try Widget.alloc(allocator, child) } };
    }

    pub fn shortcuts(allocator: std.mem.Allocator, bindings: []const Widget.ShortcutBinding, child: Widget) !Widget {
        return .{ .shortcuts = .{ .bindings = try allocator.dupe(Widget.ShortcutBinding, bindings), .child = try Widget.alloc(allocator, child) } };
    }

    pub fn image(resource: ResourceId, width: ?f32, height: ?f32, tint: ?Color) Widget {
        return .{ .image = .{ .resource = resource, .width = width, .height = height, .tint = tint } };
    }

    pub fn icon(name: []const u8, size: f32, color: ?Color) Widget {
        return .{ .icon = .{ .name = name, .size = size, .color = color } };
    }
};

pub const Element = struct {
    kind: Kind,
    widget: Widget,
    key: ?[]const u8 = null,
    document_id: DocumentId = 0,
    state: ?*anyopaque = null,
    focused: bool = false,
    render_object: ?RenderObject = null,
    render_node: ?*RenderNode = null,
    children: []Element = &.{},

    pub const Kind = enum {
        text,
        container,
        filled_button,
        gesture_detector,
        focus,
        focus_scope,
        single_child_scroll_view,
        text_field,
        row,
        column,
        spacer,
        flexible,
        sized_box,
        padding,
        center,
        shortcuts,
        default_text_style,
        image,
        icon,
    };
};

fn defaultResolvedTextStyle() ResolvedTextStyle {
    return .{ .color = colors.ink, .font_size = 16 };
}

fn roleTextStyle(theme: Theme, role: TextRole) TextStyle {
    return switch (role) {
        .body => theme.text_theme.body,
        .label => theme.text_theme.label,
        .title => theme.text_theme.title,
    };
}

fn mergeTextStyle(base: TextStyle, overlay: TextStyle) TextStyle {
    return .{
        .color = overlay.color orelse base.color,
        .font_size = overlay.font_size orelse base.font_size,
    };
}

fn resolveTextStyle(theme: Theme, inherited_style: TextStyle, text_widget: Widget.Text) ResolvedTextStyle {
    const role_style = roleTextStyle(theme, text_widget.role);
    return .{
        .color = text_widget.color orelse inherited_style.color orelse role_style.color orelse theme.color_scheme.on_surface,
        .font_size = text_widget.font_size orelse inherited_style.font_size orelse role_style.font_size orelse 16,
    };
}

fn buttonBackground(theme: Theme, hovered: bool) Color {
    if (hovered) return theme.button_theme.hover_background orelse theme.color_scheme.primary_container;
    return theme.button_theme.background orelse theme.color_scheme.primary;
}

fn buttonForeground(theme: Theme, enabled: bool, hovered: bool) Color {
    if (!enabled) return theme.button_theme.disabled_foreground orelse theme.color_scheme.on_surface_variant;
    if (hovered) return theme.button_theme.hover_foreground orelse theme.button_theme.foreground orelse theme.color_scheme.on_primary;
    return theme.button_theme.foreground orelse theme.color_scheme.on_primary;
}

fn buttonPressedBackground(theme: Theme) Color {
    return theme.button_theme.pressed_background orelse theme.color_scheme.primary_container;
}

fn buttonDisabledBackground(theme: Theme) Color {
    return theme.button_theme.disabled_background orelse theme.color_scheme.surface_container_low;
}

fn buttonFocusedBorder(theme: Theme) Color {
    return theme.button_theme.focused_border orelse theme.color_scheme.primary;
}

fn inputForeground(theme: Theme) Color {
    return theme.input_theme.foreground orelse theme.color_scheme.on_surface;
}

fn inputBackground(theme: Theme) Color {
    return theme.input_theme.background orelse theme.color_scheme.surface_container_high;
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

pub const RenderObject = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        layout: *const fn (ptr: *anyopaque, context: LayoutContext) anyerror!Size,
        paint: *const fn (ptr: *anyopaque, context: PaintContext) anyerror!void,
        hit_test: *const fn (ptr: *anyopaque, rect: Rect, point: Point) ?[]const u8,
        clone: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!RenderObject,
        destroy: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub const LayoutContext = struct {
        constraints: Constraints,
        text_measurer: TextMeasurer,
    };

    pub const PaintContext = struct {
        allocator: std.mem.Allocator,
        display_list: *DisplayList,
        rect: Rect,
    };

    pub fn layout(self: RenderObject, context: LayoutContext) !Size {
        return self.vtable.layout(self.ptr, context);
    }

    pub fn paint(self: RenderObject, context: PaintContext) !void {
        try self.vtable.paint(self.ptr, context);
    }

    pub fn hitTest(self: RenderObject, rect: Rect, point: Point) ?[]const u8 {
        return self.vtable.hit_test(self.ptr, rect, point);
    }

    pub fn clone(self: RenderObject, allocator: std.mem.Allocator) !RenderObject {
        return self.vtable.clone(self.ptr, allocator);
    }

    pub fn destroy(self: RenderObject, allocator: std.mem.Allocator) void {
        self.vtable.destroy(self.ptr, allocator);
    }
};

pub const RenderFactory = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        image: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, widget: Widget.Image) anyerror!RenderObject,
        icon: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, widget: Widget.Icon) anyerror!RenderObject,
    };

    pub fn image(self: RenderFactory, allocator: std.mem.Allocator, widget: Widget.Image) !RenderObject {
        return self.vtable.image(self.ptr, allocator, widget);
    }

    pub fn icon(self: RenderFactory, allocator: std.mem.Allocator, widget: Widget.Icon) !RenderObject {
        return self.vtable.icon(self.ptr, allocator, widget);
    }
};

pub const RenderNode = struct {
    kind: Kind,
    rect: Rect,
    text: ?[]const u8 = null,
    text_style: ResolvedTextStyle = defaultResolvedTextStyle(),
    clickable_id: ?[]const u8 = null,
    handler: ?HandlerRef = null,
    click_activation: Widget.ClickActivation = .release,
    text_input_id: ?[]const u8 = null,
    focus_id: ?[]const u8 = null,
    focus_scope_id: ?[]const u8 = null,
    modal_focus_scope: bool = false,
    scroll_id: ?[]const u8 = null,
    scroll_content: Size = .{ .width = 0, .height = 0 },
    scroll_offset: Point = .{ .x = 0, .y = 0 },
    autofocus: bool = false,
    skip_traversal: bool = false,
    can_request_focus: bool = true,
    focus_change_handler: ?HandlerRef = null,
    render_object: ?RenderObject = null,
    foreground: Color = colors.ink,
    background: Color = colors.transparent,
    box_border: ?Color = null,
    box_border_width: f32 = 1,
    box_radius: f32 = 0,
    placeholder: ?[]const u8 = null,
    border: Color = colors.ink,
    focused_border: Color = colors.accent,
    placeholder_foreground: Color = Color.argb(0xff, 0x77, 0x77, 0x7d),
    padding_x: f32 = 12,
    padding_y: f32 = 8,
    focused: bool = false,
    caret_x: ?f32 = null,
    /// Constraints this node was last laid out with; cached so clean
    /// subtrees can be skipped when re-laid out with identical inputs.
    constraints: Constraints = .{ .max_width = 0, .max_height = 0 },
    needs_layout: bool = true,
    /// Union of this node's previous and current bounds accumulated since
    /// the damage was last collected; null when the node has not changed.
    damage: ?Rect = null,
    /// Child nodes are owned by the corresponding child elements; this
    /// slice only borrows them and is refreshed on every layout.
    children: []*RenderNode = &.{},

    pub const Kind = enum {
        text,
        container,
        gesture_detector,
        focus,
        focus_scope,
        single_child_scroll_view,
        text_field,
        row,
        column,
        spacer,
        flexible,
        sized_box,
        padding,
        center,
        shortcuts,
        default_text_style,
        image,
        icon,
    };
};

pub const PaintCommand = union(enum) {
    fill_rect: FillRect,
    text: TextRun,
    alpha_image: AlphaImage,
    color_image: ColorImage,
    /// Clips subsequent commands to the given rect (logical coordinates)
    /// until the next set_clip; null removes clipping. The rect is already
    /// resolved against enclosing clips, so backends need no stack.
    set_clip: ?Rect,

    pub const FillRect = struct {
        rect: Rect,
        color: Color,
    };

    pub const TextRun = struct {
        origin: Point,
        value: []const u8,
        style: ResolvedTextStyle,
    };

    pub const AlphaImage = struct {
        rect: Rect,
        width: u32,
        height: u32,
        alpha: []const u8,
        color: Color,
        cache_key: u64,
    };

    /// Full-color image with straight (non-premultiplied) alpha, pixels in
    /// the framework's ARGB Color layout.
    pub const ColorImage = struct {
        rect: Rect,
        width: u32,
        height: u32,
        pixels: []const Color,
        cache_key: u64,
    };
};

pub const DisplayList = struct {
    commands: std.ArrayList(PaintCommand) = .empty,
    alpha_cache: std.AutoHashMapUnmanaged(u64, AlphaCacheEntry) = .empty,
    color_cache: std.AutoHashMapUnmanaged(u64, ColorCacheEntry) = .empty,
    clip_stack: std.ArrayList(Rect) = .empty,

    const AlphaCacheEntry = struct {
        width: u32,
        height: u32,
        alpha: []u8,
    };

    const ColorCacheEntry = struct {
        width: u32,
        height: u32,
        pixels: []Color,
    };

    pub fn deinit(self: *DisplayList, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
        self.clearAlphaCache(allocator);
        self.alpha_cache.deinit(allocator);
        self.clearColorCache(allocator);
        self.color_cache.deinit(allocator);
        self.clip_stack.deinit(allocator);
    }

    fn clearColorCache(self: *DisplayList, allocator: std.mem.Allocator) void {
        var values = self.color_cache.valueIterator();
        while (values.next()) |entry| allocator.free(entry.pixels);
        self.color_cache.clearRetainingCapacity();
    }

    pub fn cachedColorImage(self: *const DisplayList, cache_key: u64, width: u32, height: u32) ?[]const Color {
        const entry = self.color_cache.get(cache_key) orelse return null;
        if (entry.width != width or entry.height != height) return null;
        return entry.pixels;
    }

    /// Appends a color image command, taking ownership of pixels into the
    /// cache keyed by cache_key (mirroring alphaImage's contract).
    pub fn colorImage(
        self: *DisplayList,
        allocator: std.mem.Allocator,
        rect: Rect,
        width: u32,
        height: u32,
        pixels: []Color,
        cache_key: u64,
    ) !void {
        var pixels_owned = true;
        errdefer if (pixels_owned) allocator.free(pixels);
        const result = try self.color_cache.getOrPut(allocator, cache_key);
        const cached_pixels = if (result.found_existing) blk: {
            if (result.value_ptr.width == width and result.value_ptr.height == height) {
                if (pixels.ptr != result.value_ptr.pixels.ptr) allocator.free(pixels);
                pixels_owned = false;
                break :blk result.value_ptr.pixels;
            }
            allocator.free(result.value_ptr.pixels);
            result.value_ptr.* = .{ .width = width, .height = height, .pixels = pixels };
            pixels_owned = false;
            break :blk pixels;
        } else blk: {
            result.value_ptr.* = .{ .width = width, .height = height, .pixels = pixels };
            pixels_owned = false;
            break :blk pixels;
        };
        try self.commands.append(allocator, .{ .color_image = .{
            .rect = rect,
            .width = width,
            .height = height,
            .pixels = cached_pixels,
            .cache_key = cache_key,
        } });
    }

    pub fn clearRetainingCapacity(self: *DisplayList, _: std.mem.Allocator) void {
        self.commands.clearRetainingCapacity();
        self.clip_stack.clearRetainingCapacity();
    }

    /// Clips subsequent commands to rect intersected with any enclosing
    /// clips. Every pushClip must be matched by a popClip.
    pub fn pushClip(self: *DisplayList, allocator: std.mem.Allocator, rect: Rect) !void {
        const resolved = if (self.clip_stack.items.len > 0)
            self.clip_stack.items[self.clip_stack.items.len - 1].intersect(rect)
        else
            rect;
        try self.clip_stack.append(allocator, resolved);
        try self.commands.append(allocator, .{ .set_clip = resolved });
    }

    pub fn popClip(self: *DisplayList, allocator: std.mem.Allocator) !void {
        std.debug.assert(self.clip_stack.items.len > 0);
        _ = self.clip_stack.pop();
        const restored: ?Rect = if (self.clip_stack.items.len > 0)
            self.clip_stack.items[self.clip_stack.items.len - 1]
        else
            null;
        try self.commands.append(allocator, .{ .set_clip = restored });
    }

    fn clearAlphaCache(self: *DisplayList, allocator: std.mem.Allocator) void {
        var values = self.alpha_cache.valueIterator();
        while (values.next()) |entry| allocator.free(entry.alpha);
        self.alpha_cache.clearRetainingCapacity();
    }

    pub fn cachedAlphaImage(self: *const DisplayList, cache_key: u64, width: u32, height: u32) ?[]const u8 {
        const entry = self.alpha_cache.get(cache_key) orelse return null;
        if (entry.width != width or entry.height != height) return null;
        return entry.alpha;
    }

    pub fn fillRect(self: *DisplayList, allocator: std.mem.Allocator, rect: Rect, color: Color) !void {
        try self.commands.append(allocator, .{ .fill_rect = .{ .rect = rect, .color = color } });
    }

    pub fn text(self: *DisplayList, allocator: std.mem.Allocator, origin: Point, value: []const u8, style: ResolvedTextStyle) !void {
        try self.commands.append(allocator, .{ .text = .{ .origin = origin, .value = value, .style = style } });
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
        var alpha_owned = true;
        errdefer if (alpha_owned) allocator.free(alpha);
        const result = try self.alpha_cache.getOrPut(allocator, cache_key);
        const cached_alpha = if (result.found_existing) blk: {
            if (result.value_ptr.width == width and result.value_ptr.height == height) {
                if (alpha.ptr != result.value_ptr.alpha.ptr) allocator.free(alpha);
                alpha_owned = false;
                break :blk result.value_ptr.alpha;
            }
            allocator.free(result.value_ptr.alpha);
            result.value_ptr.* = .{ .width = width, .height = height, .alpha = alpha };
            alpha_owned = false;
            break :blk alpha;
        } else blk: {
            result.value_ptr.* = .{ .width = width, .height = height, .alpha = alpha };
            alpha_owned = false;
            break :blk alpha;
        };
        try self.commands.append(allocator, .{ .alpha_image = .{
            .rect = rect,
            .width = width,
            .height = height,
            .alpha = cached_alpha,
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
        measure_text: *const fn (ptr: *anyopaque, value: []const u8, style: ResolvedTextStyle) anyerror!Size,
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

    pub fn measureText(self: RenderBackend, value: []const u8, style: ResolvedTextStyle) !Size {
        return self.vtable.measure_text(self.ptr, value, style);
    }

    pub fn scale(self: RenderBackend) f32 {
        return self.vtable.scale(self.ptr);
    }
};

pub const TextMeasurer = union(enum) {
    fixed,
    backend: RenderBackend,

    pub fn measureText(self: TextMeasurer, value: []const u8, style: ResolvedTextStyle) !Size {
        return switch (self) {
            .fixed => fixedMeasureText(value, style),
            .backend => |backend| backend.measureText(value, style),
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
                    "text x={d} y={d} value=\"{s}\" color=#{x:0>8} size={d}\n",
                    .{ run.origin.x, run.origin.y, run.value, @as(u32, @bitCast(run.style.color)), run.style.font_size },
                ),
                .alpha_image => |image| try self.writer.print(
                    "alpha_image x={d} y={d} w={d} h={d} pixels={d}x{d} color=#{x:0>8}\n",
                    .{ image.rect.x, image.rect.y, image.rect.width, image.rect.height, image.width, image.height, @as(u32, @bitCast(image.color)) },
                ),
                .color_image => |image| try self.writer.print(
                    "color_image x={d} y={d} w={d} h={d} pixels={d}x{d}\n",
                    .{ image.rect.x, image.rect.y, image.rect.width, image.rect.height, image.width, image.height },
                ),
                .set_clip => |clip| if (clip) |rect| {
                    try self.writer.print(
                        "set_clip x={d} y={d} w={d} h={d}\n",
                        .{ rect.x, rect.y, rect.width, rect.height },
                    );
                } else {
                    try self.writer.print("set_clip none\n", .{});
                },
            }
        }
        return false;
    }

    fn measureText(_: *anyopaque, value: []const u8, style: ResolvedTextStyle) !Size {
        return fixedMeasureText(value, style);
    }

    fn scale(_: *anyopaque) f32 {
        return 1;
    }
};

const text_width_ratio = 0.5;
const input_min_width = 220;
const LayoutError = anyerror;

pub const KeyInput = union(enum) {
    text: []const u8,
    backspace,
    enter,
    space,
    tab: struct { reverse: bool = false },
    escape,
    up,
    down,
};

pub const CursorShape = enum {
    default,
    pointer,
    text,
};

/// Editing state owned by a text field element; the single source of truth
/// for the input's text after creation.
pub const TextInputState = struct {
    text: std.ArrayList(u8) = .empty,
};

pub fn textInputState(element: *Element) *TextInputState {
    std.debug.assert(element.kind == .text_field);
    return @ptrCast(@alignCast(element.state.?));
}

/// Scroll position owned by a scroll element; clamped to the content
/// extent during layout.
pub const ScrollState = struct {
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

pub fn scrollState(element: *Element) *ScrollState {
    std.debug.assert(element.kind == .single_child_scroll_view);
    return @ptrCast(@alignCast(element.state.?));
}

fn scrollChildConstraints(constraints: Constraints, axes: Widget.ScrollAxes) Constraints {
    return .{
        .max_width = if (axes.horizontalUnbounded()) std.math.inf(f32) else constraints.max_width,
        .max_height = if (axes.verticalUnbounded()) std.math.inf(f32) else constraints.max_height,
    };
}

pub fn buildRenderTreeFromElement(
    allocator: std.mem.Allocator,
    element: *Element,
    constraints: Constraints,
    backend: RenderBackend,
) !*RenderNode {
    return layoutElement(allocator, element, constraints, .{ .x = 0, .y = 0 }, .{ .backend = backend });
}

pub fn buildElementTree(allocator: std.mem.Allocator, widget: *const Widget, constraints: Constraints) anyerror!Element {
    var scope: BuildScope = .{};
    return buildElementTreeScoped(allocator, &scope, widget, constraints);
}

pub fn buildElementTreeScoped(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    widget: *const Widget,
    constraints: Constraints,
) anyerror!Element {
    return switch (widget.*) {
        .text => finishElement(allocator, scope, widget, .{ .kind = .text, .widget = try cloneWidgetForElementThemed(allocator, widget.*, scope.theme, scope.default_text_style) }),
        .spacer => finishElement(allocator, scope, widget, .{ .kind = .spacer, .widget = try cloneWidgetForElement(allocator, widget.*) }),
        .text_field => {
            var element_widget = try cloneWidgetForElementThemed(allocator, widget.*, scope.theme, scope.default_text_style);
            var element_owns_fields = false;
            errdefer if (!element_owns_fields) destroyElementWidget(allocator, &element_widget);
            const state = try allocator.create(TextInputState);
            errdefer if (!element_owns_fields) allocator.destroy(state);
            state.* = .{};
            try state.text.appendSlice(allocator, element_widget.text_field.value);
            element_owns_fields = true;
            return finishElement(allocator, scope, widget, .{
                .kind = .text_field,
                .widget = element_widget,
                .state = state,
                .focused = scope.interaction.isFocused(element_widget.text_field.focus_node),
            });
        },
        .image => |image_widget| {
            const factory = scope.render_factory orelse return error.MissingRenderFactory;
            var render_object = try factory.image(allocator, image_widget);
            var element_owns_fields = false;
            errdefer if (!element_owns_fields) render_object.destroy(allocator);
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            errdefer if (!element_owns_fields) destroyElementWidget(allocator, &element_widget);
            element_owns_fields = true;
            return finishElement(allocator, scope, widget, .{ .kind = .image, .widget = element_widget, .render_object = render_object });
        },
        .icon => |icon_widget| {
            const factory = scope.render_factory orelse return error.MissingRenderFactory;
            var resolved_widget = icon_widget;
            if (resolved_widget.color == null) resolved_widget.color = scope.default_icon_color;
            var render_object = try factory.icon(allocator, resolved_widget);
            var element_owns_fields = false;
            errdefer if (!element_owns_fields) render_object.destroy(allocator);
            var element_widget = try cloneWidgetForElement(allocator, .{ .icon = resolved_widget });
            errdefer if (!element_owns_fields) destroyElementWidget(allocator, &element_widget);
            element_owns_fields = true;
            return finishElement(allocator, scope, widget, .{ .kind = .icon, .widget = element_widget, .render_object = render_object });
        },
        .container => |box_widget| return buildSingleChildElement(allocator, scope, widget, .container, box_widget.child, constraints),
        .filled_button => |button_widget| blk: {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            var element_owns_fields = false;
            errdefer if (!element_owns_fields) destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (!element_owns_fields) {
                    if (initialized) destroyElementTree(allocator, &children[0]);
                    allocator.free(children);
                }
            }
            children[0] = try buildButtonChildElement(allocator, scope, button_widget, constraints);
            initialized = true;
            element_owns_fields = true;
            break :blk try finishElement(allocator, scope, widget, .{ .kind = .filled_button, .widget = element_widget, .children = children });
        },
        .gesture_detector => |clickable_widget| blk: {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            var element_owns_fields = false;
            errdefer if (!element_owns_fields) destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (!element_owns_fields) {
                    if (initialized) destroyElementTree(allocator, &children[0]);
                    allocator.free(children);
                }
            }
            children[0] = try buildClickableChildElement(allocator, scope, clickable_widget, constraints);
            initialized = true;
            element_owns_fields = true;
            break :blk try finishElement(allocator, scope, widget, .{ .kind = .gesture_detector, .widget = element_widget, .children = children });
        },
        .focus => |focus_widget| blk: {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            var element_owns_fields = false;
            errdefer if (!element_owns_fields) destroyElementWidget(allocator, &element_widget);
            const children = try allocator.alloc(Element, 1);
            var initialized = false;
            errdefer {
                if (!element_owns_fields) {
                    if (initialized) destroyElementTree(allocator, &children[0]);
                    allocator.free(children);
                }
            }
            children[0] = try buildElementTreeScoped(allocator, scope, focus_widget.child, constraints);
            initialized = true;
            element_owns_fields = true;
            break :blk try finishElement(allocator, scope, widget, .{ .kind = .focus, .widget = element_widget, .focused = scope.interaction.isFocused(element_widget.focus.node), .children = children });
        },
        .single_child_scroll_view => |scroll_widget| blk: {
            var element_widget = try cloneWidgetForElement(allocator, widget.*);
            var element_owns_fields = false;
            errdefer if (!element_owns_fields) destroyElementWidget(allocator, &element_widget);
            const state = try allocator.create(ScrollState);
            errdefer if (!element_owns_fields) allocator.destroy(state);
            state.* = .{};
            const children = try allocator.alloc(Element, 1);
            errdefer if (!element_owns_fields) allocator.free(children);
            children[0] = try buildElementTreeScoped(allocator, scope, scroll_widget.child, scrollChildConstraints(constraints, scroll_widget.axes));
            element_owns_fields = true;
            break :blk try finishElement(allocator, scope, widget, .{ .kind = .single_child_scroll_view, .widget = element_widget, .state = state, .children = children });
        },
        .focus_scope => |focus_scope_widget| return buildSingleChildElement(allocator, scope, widget, .focus_scope, focus_scope_widget.child, constraints),
        .padding => |padding_widget| return buildSingleChildElement(allocator, scope, widget, .padding, padding_widget.child, constraints.inset(padding_widget.insets)),
        .flexible => |flexible_widget| return buildSingleChildElement(allocator, scope, widget, .flexible, flexible_widget.child, constraints),
        .center => |center_widget| return buildSingleChildElement(allocator, scope, widget, .center, center_widget.child, constraints),
        .shortcuts => |shortcuts_widget| return buildSingleChildElement(allocator, scope, widget, .shortcuts, shortcuts_widget.child, constraints),
        .sized_box => |sized_widget| return buildSingleChildElement(allocator, scope, widget, .sized_box, sized_widget.child, constrainSized(constraints, sized_widget)),
        .default_text_style => |default_text_style| {
            const previous_style = scope.default_text_style;
            scope.default_text_style = mergeTextStyle(previous_style, default_text_style.style);
            defer scope.default_text_style = previous_style;
            return buildSingleChildElement(allocator, scope, widget, .default_text_style, default_text_style.child, constraints);
        },
        .row => |row_widget| return buildLinearElementTree(allocator, scope, .row, widget.*, row_widget.children, constraints),
        .column => |column_widget| return buildLinearElementTree(allocator, scope, .column, widget.*, column_widget.children, constraints),
    };
}

fn finishElement(allocator: std.mem.Allocator, scope: *const BuildScope, widget: *const Widget, element: Element) !Element {
    var result = element;
    errdefer destroyElementTree(allocator, &result);
    result.document_id = scope.document_id;
    result.key = if (widgetKey(widget.*)) |key| try allocator.dupe(u8, key) else null;
    return result;
}

fn buildSingleChildElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    widget: *const Widget,
    kind: Element.Kind,
    child_widget: *const Widget,
    constraints: Constraints,
) !Element {
    var element_widget = try cloneWidgetForElement(allocator, widget.*);
    var element_owns_fields = false;
    errdefer if (!element_owns_fields) destroyElementWidget(allocator, &element_widget);
    const children = try allocator.alloc(Element, 1);
    var initialized = false;
    errdefer {
        if (!element_owns_fields) {
            if (initialized) destroyElementTree(allocator, &children[0]);
            allocator.free(children);
        }
    }
    children[0] = try buildElementTreeScoped(allocator, scope, child_widget, constraints);
    initialized = true;
    element_owns_fields = true;
    return finishElement(allocator, scope, widget, .{ .kind = kind, .widget = element_widget, .children = children });
}

fn buildButtonChildElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    button_widget: Widget.FilledButton,
    constraints: Constraints,
) !Element {
    var composition: ButtonComposition = undefined;
    composition.init(scope.theme, scope.interaction, button_widget);
    const previous_icon_color = scope.default_icon_color;
    scope.default_icon_color = composition.foreground;
    defer scope.default_icon_color = previous_icon_color;
    return buildElementTreeScoped(allocator, scope, &composition.surface, constraints);
}

const ButtonComposition = struct {
    styled_child: Widget,
    padded_child: Widget,
    surface: Widget,
    foreground: Color,

    fn init(self: *ButtonComposition, theme: Theme, interaction: InteractionState, button_widget: Widget.FilledButton) void {
        const enabled = button_widget.handler != null;
        const hovered = enabled and interaction.isHovered(button_widget.id);
        const pressed = enabled and interaction.isPressed(button_widget.id);
        const focused = enabled and interaction.isFocused(.named(button_widget.id));
        self.foreground = buttonForeground(theme, enabled, hovered);
        self.styled_child = .{ .default_text_style = .{
            .style = .{ .color = self.foreground },
            .child = button_widget.child,
        } };
        self.padded_child = .{ .padding = .{
            .insets = .{
                .left = theme.button_theme.padding_x,
                .top = theme.button_theme.padding_y,
                .right = theme.button_theme.padding_x,
                .bottom = theme.button_theme.padding_y,
            },
            .child = &self.styled_child,
        } };
        self.surface = .{ .container = .{
            .child = &self.padded_child,
            .background = if (!enabled) buttonDisabledBackground(theme) else if (pressed) buttonPressedBackground(theme) else buttonBackground(theme, hovered),
            .border = if (focused) buttonFocusedBorder(theme) else null,
            .radius = theme.button_theme.radius,
        } };
    }
};

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
    var element_owns_fields = false;
    errdefer if (!element_owns_fields) destroyElementWidget(allocator, &element_widget);
    const children = try allocator.alloc(Element, child_widgets.len);
    var initialized: usize = 0;
    errdefer {
        if (!element_owns_fields) {
            for (children[0..initialized]) |*child| destroyElementTree(allocator, child);
            allocator.free(children);
        }
    }

    for (child_widgets, 0..) |*child_widget, index| {
        children[index] = try buildElementTreeScoped(allocator, scope, child_widget, constraints);
        initialized += 1;
    }

    element_owns_fields = true;
    return finishElement(allocator, scope, &widget, .{ .kind = kind, .widget = element_widget, .children = children });
}

pub fn destroyElementTree(allocator: std.mem.Allocator, element: *Element) void {
    if (element.render_node) |node| {
        allocator.free(node.children);
        allocator.destroy(node);
        element.render_node = null;
    }
    for (element.children) |*child| destroyElementTree(allocator, child);
    allocator.free(element.children);
    element.children = &.{};
    if (element.state) |state| {
        switch (element.kind) {
            .text_field => {
                const input_state: *TextInputState = @ptrCast(@alignCast(state));
                input_state.text.deinit(allocator);
                allocator.destroy(input_state);
            },
            .single_child_scroll_view => allocator.destroy(@as(*ScrollState, @ptrCast(@alignCast(state)))),
            else => unreachable,
        }
        element.state = null;
    }
    if (element.key) |key| {
        allocator.free(key);
        element.key = null;
    }
    if (element.render_object) |render_object| {
        render_object.destroy(allocator);
        element.render_object = null;
    }
    destroyElementWidget(allocator, &element.widget);
}

pub fn updateElementTree(allocator: std.mem.Allocator, element: *Element, widget: *const Widget, constraints: Constraints) anyerror!void {
    var scope: BuildScope = .{};
    try updateElementTreeScoped(allocator, &scope, element, widget, constraints);
}

pub fn updateElementTreeScoped(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    widget: *const Widget,
    constraints: Constraints,
) anyerror!void {
    // Every element this update visits gets its widget replaced, so its
    // cached layout can no longer be trusted.
    markElementLayoutDirty(element);
    if (!canUpdateElement(element, widget)) {
        var replacement = try buildElementTreeScoped(allocator, scope, widget, constraints);
        errdefer destroyElementTree(allocator, &replacement);
        destroyElementTree(allocator, element);
        element.* = replacement;
        return;
    }

    element.document_id = scope.document_id;
    switch (widget.*) {
        .text => try replaceElementWidgetThemed(allocator, scope, element, widget, scope.theme, scope.default_text_style),
        .spacer => try replaceElementWidget(allocator, scope, element, widget),
        .text_field => {
            try replaceElementWidgetThemed(allocator, scope, element, widget, scope.theme, scope.default_text_style);
            element.focused = scope.interaction.isFocused(element.widget.text_field.focus_node);
        },
        .image => |image_widget| {
            const factory = scope.render_factory orelse return error.MissingRenderFactory;
            var render_object = try factory.image(allocator, image_widget);
            errdefer render_object.destroy(allocator);
            try replaceElementWidget(allocator, scope, element, widget);
            if (element.render_object) |old| old.destroy(allocator);
            element.render_object = render_object;
        },
        .icon => |icon_widget| {
            const factory = scope.render_factory orelse return error.MissingRenderFactory;
            var resolved_widget = icon_widget;
            if (resolved_widget.color == null) resolved_widget.color = scope.default_icon_color;
            var render_object = try factory.icon(allocator, resolved_widget);
            errdefer render_object.destroy(allocator);
            const resolved: Widget = .{ .icon = resolved_widget };
            try replaceElementWidget(allocator, scope, element, &resolved);
            if (element.render_object) |old| old.destroy(allocator);
            element.render_object = render_object;
        },
        .container => |box_widget| try updateSingleChildElement(allocator, scope, element, widget, box_widget.child, constraints),
        .filled_button => |button_widget| try updateButtonElement(allocator, scope, element, widget, button_widget, constraints),
        .gesture_detector => |clickable_widget| try updateSingleChildElement(allocator, scope, element, widget, clickable_widget.child, constraints),
        .focus => |focus_widget| {
            try updateSingleChildElement(allocator, scope, element, widget, focus_widget.child, constraints);
            element.focused = scope.interaction.isFocused(element.widget.focus.node);
        },
        .single_child_scroll_view => |scroll_widget| try updateSingleChildElement(allocator, scope, element, widget, scroll_widget.child, scrollChildConstraints(constraints, scroll_widget.axes)),
        .focus_scope => |focus_scope_widget| try updateSingleChildElement(allocator, scope, element, widget, focus_scope_widget.child, constraints),
        .padding => |padding_widget| try updateSingleChildElement(allocator, scope, element, widget, padding_widget.child, constraints.inset(padding_widget.insets)),
        .flexible => |flexible_widget| try updateSingleChildElement(allocator, scope, element, widget, flexible_widget.child, constraints),
        .center => |center_widget| try updateSingleChildElement(allocator, scope, element, widget, center_widget.child, constraints),
        .shortcuts => |shortcuts_widget| try updateSingleChildElement(allocator, scope, element, widget, shortcuts_widget.child, constraints),
        .sized_box => |sized_widget| try updateSingleChildElement(allocator, scope, element, widget, sized_widget.child, constrainSized(constraints, sized_widget)),
        .default_text_style => |default_text_style| {
            const previous_style = scope.default_text_style;
            scope.default_text_style = mergeTextStyle(previous_style, default_text_style.style);
            defer scope.default_text_style = previous_style;
            try updateSingleChildElement(allocator, scope, element, widget, default_text_style.child, constraints);
        },
        .row => |row_widget| try updateLinearElement(allocator, scope, element, widget.*, row_widget.children, constraints),
        .column => |column_widget| try updateLinearElement(allocator, scope, element, widget.*, column_widget.children, constraints),
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
        .text_field,
        .image,
        .icon,
        => return false,

        .container,
        .sized_box,
        .filled_button,
        .gesture_detector,
        .focus,
        .focus_scope,
        .center,
        .flexible,
        .shortcuts,
        => return try rebuildDirtySingleChildElement(allocator, scope, element, constraints),

        .single_child_scroll_view => |scroll_widget| return try rebuildDirtySingleChildElement(allocator, scope, element, scrollChildConstraints(constraints, scroll_widget.axes)),
        .padding => |padding_widget| return try rebuildDirtySingleChildElement(allocator, scope, element, constraints.inset(padding_widget.insets)),
        .default_text_style => |default_text_style| {
            const previous_style = scope.default_text_style;
            scope.default_text_style = mergeTextStyle(previous_style, default_text_style.style);
            defer scope.default_text_style = previous_style;
            return try rebuildDirtySingleChildElement(allocator, scope, element, constraints);
        },
        .row, .column => {
            const rebuilt = try rebuildDirtyChildren(allocator, scope, element.children, constraints);
            if (rebuilt) markElementLayoutDirty(element);
            return rebuilt;
        },
    }
}

/// Finds the text input element with the given focus id, marking the
/// layout path to it dirty so an edit relayouts exactly that input.
pub fn dirtyTextInputElement(element: *Element, focus_id: []const u8) ?*Element {
    if (element.kind == .text_field) {
        if (std.mem.eql(u8, element.widget.text_field.focus_node.id, focus_id)) {
            markElementLayoutDirty(element);
            return element;
        }
        return null;
    }
    for (element.children) |*child| {
        if (dirtyTextInputElement(child, focus_id)) |found| {
            markElementLayoutDirty(element);
            return found;
        }
    }
    return null;
}

/// Finds the scroll element with the given id, marking the layout path to
/// it dirty so a scroll relayouts exactly that viewport.
pub fn dirtyScrollElement(element: *Element, scroll_id: []const u8) ?*Element {
    const id: ?[]const u8 = switch (element.kind) {
        .single_child_scroll_view => element.widget.single_child_scroll_view.id,
        else => null,
    };
    if (id) |element_id| {
        if (std.mem.eql(u8, element_id, scroll_id)) {
            markElementLayoutDirty(element);
            return element;
        }
    }
    for (element.children) |*child| {
        if (dirtyScrollElement(child, scroll_id)) |found| {
            markElementLayoutDirty(element);
            return found;
        }
    }
    return null;
}

/// Re-expands interaction-styled elements whose id is in `ids`
/// using the scope's current interaction state, so hover/press changes can
/// restyle exactly the affected widgets instead of rebuilding the app.
/// Ancestors of refreshed elements are marked for relayout.
pub fn refreshInteractionElements(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    constraints: Constraints,
    ids: []const []const u8,
) anyerror!bool {
    switch (element.widget) {
        .text,
        .spacer,
        .text_field,
        .image,
        .icon,
        => return false,

        .gesture_detector => |clickable_widget| {
            var matched = false;
            for (ids) |id| {
                if (std.mem.eql(u8, clickable_widget.id, id)) matched = true;
            }
            if (matched and clickable_widget.hover_style != null) {
                applyClickableHoverStyle(&element.children[0], clickable_widget, scope.interaction);
                markElementLayoutDirty(&element.children[0]);
                markElementLayoutDirty(element);
                return true;
            }
            return try refreshInteractionSingleChild(allocator, scope, element, constraints, ids);
        },

        .filled_button => |button_widget| {
            var matched = false;
            for (ids) |id| {
                if (std.mem.eql(u8, button_widget.id, id)) matched = true;
            }
            if (matched) {
                try updateButtonChildElement(allocator, scope, &element.children[0], button_widget, constraints);
                markElementLayoutDirty(element);
                return true;
            }
            return try refreshInteractionSingleChild(allocator, scope, element, constraints, ids);
        },

        .container,
        .sized_box,
        .focus,
        .focus_scope,
        .center,
        .flexible,
        .shortcuts,
        => return try refreshInteractionSingleChild(allocator, scope, element, constraints, ids),

        .single_child_scroll_view => |scroll_widget| return try refreshInteractionSingleChild(allocator, scope, element, scrollChildConstraints(constraints, scroll_widget.axes), ids),
        .padding => |padding_widget| return try refreshInteractionSingleChild(allocator, scope, element, constraints.inset(padding_widget.insets), ids),
        .default_text_style => |default_text_style| {
            const previous_style = scope.default_text_style;
            scope.default_text_style = mergeTextStyle(previous_style, default_text_style.style);
            defer scope.default_text_style = previous_style;
            return try refreshInteractionSingleChild(allocator, scope, element, constraints, ids);
        },
        .row, .column => {
            var refreshed = false;
            for (element.children) |*child| {
                if (try refreshInteractionElements(allocator, scope, child, constraints, ids)) refreshed = true;
            }
            if (refreshed) markElementLayoutDirty(element);
            return refreshed;
        },
    }
}

fn refreshInteractionSingleChild(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    constraints: Constraints,
    ids: []const []const u8,
) !bool {
    std.debug.assert(element.children.len == 1);
    const refreshed = try refreshInteractionElements(allocator, scope, &element.children[0], constraints, ids);
    if (refreshed) markElementLayoutDirty(element);
    return refreshed;
}

fn rebuildDirtySingleChildElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    constraints: Constraints,
) !bool {
    std.debug.assert(element.children.len == 1);
    // A rebuilt descendant may change size, so every ancestor on the path
    // must re-run layout even though its own widget is unchanged.
    const rebuilt = try rebuildDirtyElementTreeScoped(allocator, scope, &element.children[0], constraints);
    if (rebuilt) markElementLayoutDirty(element);
    return rebuilt;
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
    if (element.kind != elementKindForWidget(widget.*)) return false;
    const old_key = element.key;
    const new_key = widgetKey(widget.*);
    if (old_key == null and new_key == null) return true;
    if (old_key == null or new_key == null) return false;
    return std.mem.eql(u8, old_key.?, new_key.?);
}

fn elementKindForWidget(widget: Widget) Element.Kind {
    return switch (widget) {
        .text => .text,
        .container => .container,
        .filled_button => .filled_button,
        .gesture_detector => .gesture_detector,
        .focus => .focus,
        .focus_scope => .focus_scope,
        .single_child_scroll_view => .single_child_scroll_view,
        .text_field => .text_field,
        .row => .row,
        .column => .column,
        .spacer => .spacer,
        .flexible => .flexible,
        .sized_box => .sized_box,
        .padding => .padding,
        .center => .center,
        .shortcuts => .shortcuts,
        .default_text_style => .default_text_style,
        .image => .image,
        .icon => .icon,
    };
}

fn updateSingleChildElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    widget: *const Widget,
    child_widget: *const Widget,
    child_constraints: Constraints,
) anyerror!void {
    std.debug.assert(element.children.len == 1);
    var element_widget = try cloneWidgetForElement(allocator, widget.*);
    errdefer destroyElementWidget(allocator, &element_widget);
    const new_key = try cloneElementKey(allocator, widget.*);
    errdefer if (new_key) |key| allocator.free(key);
    try updateElementTreeScoped(allocator, scope, &element.children[0], child_widget, child_constraints);

    // All fallible work is complete before ownership is transferred.
    destroyElementWidget(allocator, &element.widget);
    if (element.key) |old_key| allocator.free(old_key);
    element.widget = element_widget;
    element.key = new_key;
    element.document_id = scope.document_id;
}

fn updateButtonElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    widget: *const Widget,
    button_widget: Widget.FilledButton,
    constraints: Constraints,
) !void {
    std.debug.assert(element.children.len == 1);
    var element_widget = try cloneWidgetForElement(allocator, widget.*);
    errdefer destroyElementWidget(allocator, &element_widget);
    const new_key = try cloneElementKey(allocator, widget.*);
    errdefer if (new_key) |key| allocator.free(key);

    try updateButtonChildElement(allocator, scope, &element.children[0], button_widget, constraints);

    destroyElementWidget(allocator, &element.widget);
    if (element.key) |old_key| allocator.free(old_key);
    element.widget = element_widget;
    element.key = new_key;
    element.document_id = scope.document_id;
}

fn updateButtonChildElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    element: *Element,
    button_widget: Widget.FilledButton,
    constraints: Constraints,
) !void {
    var composition: ButtonComposition = undefined;
    composition.init(scope.theme, scope.interaction, button_widget);
    const previous_icon_color = scope.default_icon_color;
    scope.default_icon_color = composition.foreground;
    defer scope.default_icon_color = previous_icon_color;
    try updateElementTreeScoped(allocator, scope, element, &composition.surface, constraints);
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
    const new_key = try cloneElementKey(allocator, widget);
    errdefer if (new_key) |key| allocator.free(key);
    for (child_widgets, 0..) |*child_widget, index| {
        try updateElementTreeScoped(allocator, scope, &element.children[index], child_widget, constraints);
    }

    // All fallible work is complete before ownership is transferred.
    destroyElementWidget(allocator, &element.widget);
    if (element.key) |old_key| allocator.free(old_key);
    element.widget = element_widget;
    element.key = new_key;
    element.document_id = scope.document_id;
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

    const origins = try allocator.alloc(?usize, child_widgets.len);
    defer allocator.free(origins);
    @memset(origins, null);
    const new_children = try allocator.alloc(Element, child_widgets.len);
    var initialized: usize = 0;
    errdefer {
        for (new_children[0..initialized], origins[0..initialized]) |*child, origin| {
            if (origin) |old_index| {
                old_children[old_index] = child.*;
            } else {
                destroyElementTree(allocator, child);
            }
        }
        allocator.free(new_children);
    }

    for (child_widgets, 0..) |*child_widget, index| {
        if (widgetKey(child_widget.*)) |key| {
            if (findElementByKey(old_children, used, key)) |old_index| {
                used[old_index] = true;
                new_children[index] = old_children[old_index];
                origins[index] = old_index;
                initialized += 1;
                try updateElementTreeScoped(allocator, scope, &new_children[index], child_widget, constraints);
                continue;
            }
        } else if (index < old_children.len and !used[index] and old_children[index].key == null) {
            used[index] = true;
            new_children[index] = old_children[index];
            origins[index] = index;
            initialized += 1;
            try updateElementTreeScoped(allocator, scope, &new_children[index], child_widget, constraints);
            continue;
        }

        new_children[index] = try buildElementTreeScoped(allocator, scope, child_widget, constraints);
        initialized += 1;
    }

    const new_key = if (widgetKey(widget)) |key| try allocator.dupe(u8, key) else null;
    errdefer if (new_key) |key| allocator.free(key);

    for (old_children, 0..) |*old_child, index| {
        if (!used[index]) destroyElementTree(allocator, old_child);
    }
    allocator.free(old_children);
    destroyElementWidget(allocator, &element.widget);
    if (element.key) |old_key| allocator.free(old_key);
    element.widget = element_widget;
    element.key = new_key;
    element.document_id = scope.document_id;
    element.children = new_children;
}

fn hasKeyedChildren(children: []const Element) bool {
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

fn findElementByKey(children: []const Element, used: []const bool, key: []const u8) ?usize {
    for (children, 0..) |child, index| {
        if (used[index]) continue;
        const child_key = child.key orelse continue;
        if (std.mem.eql(u8, child_key, key)) return index;
    }
    return null;
}

fn widgetKey(widget: Widget) ?[]const u8 {
    return switch (widget) {
        .text => |value| value.key,
        .container => |value| value.key,
        .filled_button => |value| value.key,
        .gesture_detector => |value| value.key,
        .focus => |value| value.key,
        .focus_scope => |value| value.key,
        .single_child_scroll_view => |value| value.key,
        .text_field => |value| value.key,
        .row => |value| value.key,
        .column => |value| value.key,
        .spacer => |value| value.key,
        .flexible => |value| value.key,
        .sized_box => |value| value.key,
        .padding => |value| value.key,
        .center => |value| value.key,
        .shortcuts => |value| value.key,
        .default_text_style => |value| value.key,
        .image => |value| value.key,
        .icon => |value| value.key,
    };
}

fn cloneElementKey(allocator: std.mem.Allocator, widget: Widget) !?[]u8 {
    return if (widgetKey(widget)) |key| try allocator.dupe(u8, key) else null;
}

fn replaceElementWidget(allocator: std.mem.Allocator, scope: *BuildScope, element: *Element, widget: *const Widget) anyerror!void {
    var element_widget = try cloneWidgetForElement(allocator, widget.*);
    errdefer destroyElementWidget(allocator, &element_widget);
    const new_key = try cloneElementKey(allocator, widget.*);
    errdefer if (new_key) |key| allocator.free(key);

    // All fallible work is complete before ownership is transferred.
    destroyElementWidget(allocator, &element.widget);
    if (element.key) |old_key| allocator.free(old_key);
    element.widget = element_widget;
    element.key = new_key;
    element.document_id = scope.document_id;
}

fn replaceElementWidgetThemed(allocator: std.mem.Allocator, scope: *BuildScope, element: *Element, widget: *const Widget, theme: Theme, inherited_style: TextStyle) anyerror!void {
    var element_widget = try cloneWidgetForElementThemed(allocator, widget.*, theme, inherited_style);
    errdefer destroyElementWidget(allocator, &element_widget);
    const new_key = try cloneElementKey(allocator, widget.*);
    errdefer if (new_key) |key| allocator.free(key);

    // All fallible work is complete before ownership is transferred.
    destroyElementWidget(allocator, &element.widget);
    if (element.key) |old_key| allocator.free(old_key);
    element.widget = element_widget;
    element.key = new_key;
    element.document_id = scope.document_id;
}

fn cloneWidgetForElementThemed(allocator: std.mem.Allocator, widget: Widget, theme: Theme, inherited_style: TextStyle) !Widget {
    var result = try cloneWidgetForElement(allocator, widget);
    switch (result) {
        .text => |*text_widget| {
            const style = resolveTextStyle(theme, inherited_style, text_widget.*);
            text_widget.color = style.color;
            text_widget.font_size = style.font_size;
        },
        .text_field => |*input_widget| {
            input_widget.foreground = inputForeground(theme);
            input_widget.background = inputBackground(theme);
            input_widget.border = inputBorder(theme);
            input_widget.focused_border = inputFocusedBorder(theme);
            input_widget.placeholder_foreground = inputPlaceholder(theme);
            input_widget.padding_x = theme.input_theme.padding_x;
            input_widget.padding_y = theme.input_theme.padding_y;
            input_widget.radius = theme.input_theme.radius;
        },
        else => {},
    }
    return result;
}

fn buildClickableChildElement(
    allocator: std.mem.Allocator,
    scope: *BuildScope,
    clickable_widget: Widget.GestureDetector,
    constraints: Constraints,
) !Element {
    const child = clickableStyledChild(clickable_widget, scope.interaction);
    return buildElementTreeScoped(allocator, scope, &child, constraints);
}

fn clickableStyledChild(clickable_widget: Widget.GestureDetector, interaction: InteractionState) Widget {
    var child = clickable_widget.child.*;
    const style = clickableActiveStyle(clickable_widget, interaction) orelse return child;
    const background = style.background orelse return child;
    switch (child) {
        .container => child.container.background = background,
        else => {},
    }
    return child;
}

fn applyClickableHoverStyle(element: *Element, clickable_widget: Widget.GestureDetector, interaction: InteractionState) void {
    const style = clickable_widget.hover_style orelse return;
    const background = if (interaction.isHovered(clickable_widget.id)) style.background else style.base_background;
    const value = background orelse return;
    switch (element.widget) {
        .container => element.widget.container.background = value,
        else => {},
    }
}

fn clickableActiveStyle(clickable_widget: Widget.GestureDetector, interaction: InteractionState) ?Widget.GestureDetectorStyle {
    if (!interaction.isHovered(clickable_widget.id)) return null;
    return clickable_widget.hover_style;
}

fn clickableHoverStyle(clickable_widget: Widget.GestureDetector) ?Widget.GestureDetectorStyle {
    var style = clickable_widget.hover_style orelse return null;
    if (style.background != null and style.base_background == null) {
        style.base_background = clickableChildBackground(clickable_widget.child);
    }
    return style;
}

fn clickableChildBackground(child: *const Widget) ?Color {
    return switch (child.*) {
        .container => |box_widget| box_widget.background,
        else => null,
    };
}

fn cloneWidgetForElement(allocator: std.mem.Allocator, widget: Widget) !Widget {
    return switch (widget) {
        .text => |text_widget| .{ .text = .{
            .key = if (text_widget.key) |key| try allocator.dupe(u8, key) else null,
            .value = try allocator.dupe(u8, text_widget.value),
            .color = text_widget.color,
            .font_size = text_widget.font_size,
            .role = text_widget.role,
        } },
        .spacer => |spacer_widget| .{ .spacer = .{ .key = if (spacer_widget.key) |key| try allocator.dupe(u8, key) else null, .flex = spacer_widget.flex } },
        .sized_box => |sized_widget| .{ .sized_box = .{ .key = if (sized_widget.key) |key| try allocator.dupe(u8, key) else null, .child = sized_widget.child, .width = sized_widget.width, .height = sized_widget.height, .min_width = sized_widget.min_width, .min_height = sized_widget.min_height, .max_width = sized_widget.max_width, .max_height = sized_widget.max_height } },
        .container => |box_widget| .{ .container = .{ .key = if (box_widget.key) |key| try allocator.dupe(u8, key) else null, .child = box_widget.child, .background = box_widget.background, .border = box_widget.border, .border_width = box_widget.border_width, .radius = box_widget.radius, .min_width = box_widget.min_width, .min_height = box_widget.min_height, .horizontal_align = box_widget.horizontal_align, .vertical_align = box_widget.vertical_align } },
        .filled_button => |button_widget| blk: {
            const key = if (button_widget.key) |value| try allocator.dupe(u8, value) else null;
            errdefer if (key) |value| allocator.free(value);
            const id = try allocator.dupe(u8, button_widget.id);
            break :blk .{ .filled_button = .{
                .key = key,
                .id = id,
                .handler = button_widget.handler,
                .child = button_widget.child,
                .activation = button_widget.activation,
            } };
        },
        .gesture_detector => |clickable_widget| blk: {
            const key = if (clickable_widget.key) |value| try allocator.dupe(u8, value) else null;
            errdefer if (key) |value| allocator.free(value);
            const id = try allocator.dupe(u8, clickable_widget.id);
            errdefer allocator.free(id);
            break :blk .{ .gesture_detector = .{
                .key = key,
                .id = id,
                .handler = clickable_widget.handler,
                .child = clickable_widget.child,
                .activation = clickable_widget.activation,
                .hover_style = clickableHoverStyle(clickable_widget),
            } };
        },
        .focus => |focus_widget| blk: {
            const key = if (focus_widget.key) |value| try allocator.dupe(u8, value) else null;
            errdefer if (key) |value| allocator.free(value);
            const focus_id = try allocator.dupe(u8, focus_widget.node.id);
            errdefer allocator.free(focus_id);
            break :blk .{ .focus = .{
                .key = key,
                .node = .named(focus_id),
                .child = focus_widget.child,
                .autofocus = focus_widget.autofocus,
                .skip_traversal = focus_widget.skip_traversal,
                .can_request_focus = focus_widget.can_request_focus,
                .on_focus_change = focus_widget.on_focus_change,
            } };
        },
        .focus_scope => |focus_scope_widget| blk: {
            const key = if (focus_scope_widget.key) |value| try allocator.dupe(u8, value) else null;
            errdefer if (key) |value| allocator.free(value);
            const id = try allocator.dupe(u8, focus_scope_widget.id);
            break :blk .{ .focus_scope = .{ .key = key, .id = id, .child = focus_scope_widget.child, .modal = focus_scope_widget.modal } };
        },
        .single_child_scroll_view => |scroll_widget| blk: {
            const key = if (scroll_widget.key) |value| try allocator.dupe(u8, value) else null;
            errdefer if (key) |value| allocator.free(value);
            const id = try allocator.dupe(u8, scroll_widget.id);
            break :blk .{ .single_child_scroll_view = .{ .key = key, .id = id, .child = scroll_widget.child, .axes = scroll_widget.axes } };
        },
        .text_field => |input_widget| blk: {
            const key = if (input_widget.key) |value| try allocator.dupe(u8, value) else null;
            errdefer if (key) |value| allocator.free(value);
            const id = try allocator.dupe(u8, input_widget.id);
            errdefer allocator.free(id);
            const focus_node_id = try allocator.dupe(u8, input_widget.focus_node.id);
            errdefer allocator.free(focus_node_id);
            const value = try allocator.dupe(u8, input_widget.value);
            errdefer allocator.free(value);
            const placeholder = try allocator.dupe(u8, input_widget.placeholder);
            errdefer allocator.free(placeholder);
            break :blk .{ .text_field = .{
                .key = key,
                .id = id,
                .focus_node = .named(focus_node_id),
                .value = value,
                .placeholder = placeholder,
                .on_change = input_widget.on_change,
                .foreground = input_widget.foreground,
                .background = input_widget.background,
                .border = input_widget.border,
                .focused_border = input_widget.focused_border,
                .placeholder_foreground = input_widget.placeholder_foreground,
                .padding_x = input_widget.padding_x,
                .padding_y = input_widget.padding_y,
                .radius = input_widget.radius,
                .autofocus = input_widget.autofocus,
            } };
        },
        .row => |row_widget| .{ .row = .{ .key = if (row_widget.key) |key| try allocator.dupe(u8, key) else null, .children = &.{}, .gap = row_widget.gap, .cross_align = row_widget.cross_align, .main_align = row_widget.main_align } },
        .column => |column_widget| .{ .column = .{ .key = if (column_widget.key) |key| try allocator.dupe(u8, key) else null, .children = &.{}, .gap = column_widget.gap, .cross_align = column_widget.cross_align, .main_align = column_widget.main_align } },
        .padding => |padding_widget| .{ .padding = .{ .key = if (padding_widget.key) |key| try allocator.dupe(u8, key) else null, .insets = padding_widget.insets, .child = padding_widget.child } },
        .center => |center_widget| .{ .center = .{ .key = if (center_widget.key) |key| try allocator.dupe(u8, key) else null, .child = center_widget.child } },
        .flexible => |flexible_widget| .{ .flexible = .{ .key = if (flexible_widget.key) |key| try allocator.dupe(u8, key) else null, .child = flexible_widget.child, .flex = flexible_widget.flex, .fit = flexible_widget.fit } },
        .shortcuts => |shortcuts_widget| .{ .shortcuts = .{
            .key = if (shortcuts_widget.key) |key| try allocator.dupe(u8, key) else null,
            .bindings = try cloneShortcutBindings(allocator, shortcuts_widget.bindings),
            .child = shortcuts_widget.child,
        } },
        .default_text_style => |default_text_style| .{ .default_text_style = .{ .key = if (default_text_style.key) |key| try allocator.dupe(u8, key) else null, .style = default_text_style.style, .child = default_text_style.child } },
        .image => |image_widget| .{ .image = .{ .key = if (image_widget.key) |key| try allocator.dupe(u8, key) else null, .resource = image_widget.resource, .width = image_widget.width, .height = image_widget.height, .tint = image_widget.tint } },
        .icon => |icon_widget| .{ .icon = .{ .key = if (icon_widget.key) |key| try allocator.dupe(u8, key) else null, .name = try allocator.dupe(u8, icon_widget.name), .size = icon_widget.size, .color = icon_widget.color } },
    };
}

fn destroyElementWidget(allocator: std.mem.Allocator, widget: *Widget) void {
    switch (widget.*) {
        .text => |text_widget| {
            if (text_widget.key) |key| allocator.free(key);
            allocator.free(text_widget.value);
        },
        .spacer => |spacer_widget| if (spacer_widget.key) |key| allocator.free(key),
        .sized_box => |sized_widget| if (sized_widget.key) |key| allocator.free(key),
        .filled_button => |button_widget| {
            if (button_widget.key) |key| allocator.free(key);
            allocator.free(button_widget.id);
        },
        .gesture_detector => |clickable_widget| {
            if (clickable_widget.key) |key| allocator.free(key);
            allocator.free(clickable_widget.id);
        },
        .focus => |focus_widget| {
            if (focus_widget.key) |key| allocator.free(key);
            allocator.free(focus_widget.node.id);
        },
        .focus_scope => |focus_scope_widget| {
            if (focus_scope_widget.key) |key| allocator.free(key);
            allocator.free(focus_scope_widget.id);
        },
        .single_child_scroll_view => |scroll_widget| {
            if (scroll_widget.key) |key| allocator.free(key);
            allocator.free(scroll_widget.id);
        },
        .text_field => |input_widget| {
            if (input_widget.key) |key| allocator.free(key);
            allocator.free(input_widget.id);
            allocator.free(input_widget.focus_node.id);
            allocator.free(input_widget.value);
            allocator.free(input_widget.placeholder);
        },
        .shortcuts => |shortcuts_widget| {
            if (shortcuts_widget.key) |key| allocator.free(key);
            destroyShortcutBindings(allocator, shortcuts_widget.bindings);
        },
        .icon => |icon_widget| {
            if (icon_widget.key) |key| allocator.free(key);
            allocator.free(icon_widget.name);
        },
        .container => |box_widget| if (box_widget.key) |key| allocator.free(key),
        .row => |row_widget| if (row_widget.key) |key| allocator.free(key),
        .column => |column_widget| if (column_widget.key) |key| allocator.free(key),
        .padding => |padding_widget| if (padding_widget.key) |key| allocator.free(key),
        .center => |center_widget| if (center_widget.key) |key| allocator.free(key),
        .flexible => |flexible_widget| if (flexible_widget.key) |key| allocator.free(key),
        .default_text_style => |default_text_style| if (default_text_style.key) |key| allocator.free(key),
        .image => |image_widget| if (image_widget.key) |key| allocator.free(key),
    }
}

fn cloneShortcutBindings(allocator: std.mem.Allocator, bindings: []const Widget.ShortcutBinding) ![]Widget.ShortcutBinding {
    const result = try allocator.alloc(Widget.ShortcutBinding, bindings.len);
    for (bindings, 0..) |binding, index| {
        result[index] = binding;
    }
    return result;
}

fn destroyShortcutBindings(allocator: std.mem.Allocator, bindings: []const Widget.ShortcutBinding) void {
    allocator.free(bindings);
}

pub fn paint(allocator: std.mem.Allocator, node: *const RenderNode, display_list: *DisplayList) !void {
    return paintScaled(allocator, node, display_list, 1);
}

pub fn paintScaled(allocator: std.mem.Allocator, node: *const RenderNode, display_list: *DisplayList, scale: f32) !void {
    switch (node.kind) {
        .image, .icon => {
            const render_object = node.render_object orelse return error.MissingRenderObject;
            try render_object.paint(.{ .allocator = allocator, .rect = node.rect, .display_list = display_list });
        },
        .container => {
            if (node.box_radius > 0) {
                try paintRoundedBox(allocator, display_list, node.rect, node.background, node.box_border, node.box_border_width, node.box_radius, scale);
            } else {
                if (node.background.a > 0) try display_list.fillRect(allocator, node.rect, node.background);
                if (node.box_border) |border| try paintBorder(allocator, display_list, node.rect, border, node.box_border_width);
            }
        },
        .text_field => {
            const border = if (node.focused) node.focused_border else node.border;
            if (node.box_radius > 0) {
                try paintRoundedBox(allocator, display_list, node.rect, node.background, border, 1, node.box_radius, scale);
            } else {
                try display_list.fillRect(allocator, node.rect, node.background);
                try paintBorder(allocator, display_list, node.rect, border, 1);
            }
            const value = node.text orelse "";
            const visible_text = if (value.len > 0) value else node.placeholder orelse "";
            const text_color = if (value.len > 0) node.foreground else node.placeholder_foreground;
            // Overflowing text and caret must not paint outside the field.
            try display_list.pushClip(allocator, node.rect);
            try display_list.text(allocator, .{
                .x = node.rect.x + node.padding_x,
                .y = node.rect.y + node.padding_y,
            }, visible_text, .{ .color = text_color, .font_size = node.text_style.font_size });
            if (node.focused) {
                const caret_x = node.caret_x orelse node.rect.x + node.padding_x;
                try display_list.fillRect(allocator, .{
                    .x = caret_x,
                    .y = node.rect.y + node.padding_y,
                    .width = 1,
                    .height = @max(1, node.rect.height - node.padding_y * 2),
                }, node.foreground);
            }
            try display_list.popClip(allocator);
        },
        .text => if (node.text) |value| {
            try display_list.text(allocator, .{ .x = node.rect.x, .y = node.rect.y }, value, node.text_style);
        },
        .single_child_scroll_view => try display_list.pushClip(allocator, node.rect),
        else => {},
    }

    for (node.children) |child| {
        try paintScaled(allocator, child, display_list, scale);
    }

    if (isViewportKind(node.kind)) {
        try paintScrollbars(allocator, node, display_list);
        try display_list.popClip(allocator);
    }
}

fn isViewportKind(kind: RenderNode.Kind) bool {
    return kind == .single_child_scroll_view;
}

const scrollbar_thickness: f32 = 4;
const scrollbar_margin: f32 = 2;
const scrollbar_min_thumb: f32 = 12;
const scrollbar_color: Color = Color.argb(0x60, 0x80, 0x80, 0x88);
/// Extra pointer slop around the painted thumb so the thin bar is
/// grabbable.
const scrollbar_hit_slop: f32 = 4;

pub const ScrollbarAxis = enum { vertical, horizontal };

const ScrollbarGeometry = struct {
    thumb: Rect,
    /// Scroll offset change per pixel of thumb travel along the track;
    /// zero when the thumb fills the track and cannot move.
    drag_scale: f32,
};

/// Thumb geometry for one axis of a viewport node, or null when the
/// content does not overflow that axis. Single source for painting and
/// pointer hit testing.
fn scrollbarGeometry(node: *const RenderNode, axis: ScrollbarAxis) ?ScrollbarGeometry {
    std.debug.assert(isViewportKind(node.kind));
    const content = node.scroll_content;
    const viewport = switch (axis) {
        .vertical => node.rect.height,
        .horizontal => node.rect.width,
    };
    const extent = switch (axis) {
        .vertical => content.height,
        .horizontal => content.width,
    };
    if (extent <= viewport) return null;

    const track = viewport - scrollbar_margin * 2;
    const thumb = @max(scrollbar_min_thumb, track * viewport / extent);
    const max_offset = extent - viewport;
    const travel = track - thumb;
    const offset = switch (axis) {
        .vertical => node.scroll_offset.y,
        .horizontal => node.scroll_offset.x,
    };
    const along = if (travel > 0) travel * (offset / max_offset) else 0;
    return switch (axis) {
        .vertical => .{
            .thumb = .{
                .x = node.rect.x + node.rect.width - scrollbar_thickness - scrollbar_margin,
                .y = node.rect.y + scrollbar_margin + along,
                .width = scrollbar_thickness,
                .height = thumb,
            },
            .drag_scale = if (travel > 0) max_offset / travel else 0,
        },
        .horizontal => .{
            .thumb = .{
                .x = node.rect.x + scrollbar_margin + along,
                .y = node.rect.y + node.rect.height - scrollbar_thickness - scrollbar_margin,
                .width = thumb,
                .height = scrollbar_thickness,
            },
            .drag_scale = if (travel > 0) max_offset / travel else 0,
        },
    };
}

/// Paints proportional scrollbar thumbs for axes whose content overflows
/// the viewport, from the geometry recorded during layout.
fn paintScrollbars(allocator: std.mem.Allocator, node: *const RenderNode, display_list: *DisplayList) !void {
    std.debug.assert(isViewportKind(node.kind));
    inline for ([_]ScrollbarAxis{ .vertical, .horizontal }) |axis| {
        if (scrollbarGeometry(node, axis)) |geometry| {
            try display_list.fillRect(allocator, geometry.thumb, scrollbar_color);
        }
    }
}

pub const ScrollbarThumbHit = struct {
    id: []const u8,
    axis: ScrollbarAxis,
    /// Scroll offset change per pixel of pointer travel along the track.
    drag_scale: f32,
};

/// Finds the innermost scrollbar thumb under the pointer, with a small
/// slop so the thin thumb is grabbable.
pub fn hitTestScrollbarThumb(node: *const RenderNode, point: Point) ?ScrollbarThumbHit {
    if (isViewportKind(node.kind) and !node.rect.contains(point)) return null;
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (hitTestScrollbarThumb(node.children[index], point)) |hit| return hit;
    }
    if (!isViewportKind(node.kind)) return null;
    const id = node.scroll_id orelse return null;
    for ([_]ScrollbarAxis{ .vertical, .horizontal }) |axis| {
        const geometry = scrollbarGeometry(node, axis) orelse continue;
        const slop: Rect = .{
            .x = geometry.thumb.x - scrollbar_hit_slop,
            .y = geometry.thumb.y - scrollbar_hit_slop,
            .width = geometry.thumb.width + scrollbar_hit_slop * 2,
            .height = geometry.thumb.height + scrollbar_hit_slop * 2,
        };
        if (slop.contains(point)) return .{ .id = id, .axis = axis, .drag_scale = geometry.drag_scale };
    }
    return null;
}

fn paintBorder(allocator: std.mem.Allocator, display_list: *DisplayList, rect: Rect, color: Color, width: f32) !void {
    const clamped_width = @min(@max(0, width), @min(rect.width, rect.height) / 2);
    if (clamped_width <= 0) return;
    try display_list.fillRect(allocator, .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = clamped_width }, color);
    try display_list.fillRect(allocator, .{ .x = rect.x, .y = rect.y + rect.height - clamped_width, .width = rect.width, .height = clamped_width }, color);
    try display_list.fillRect(allocator, .{ .x = rect.x, .y = rect.y + clamped_width, .width = clamped_width, .height = @max(0, rect.height - clamped_width * 2) }, color);
    try display_list.fillRect(allocator, .{ .x = rect.x + rect.width - clamped_width, .y = rect.y + clamped_width, .width = clamped_width, .height = @max(0, rect.height - clamped_width * 2) }, color);
}

fn paintRoundedBox(
    allocator: std.mem.Allocator,
    display_list: *DisplayList,
    rect: Rect,
    background: Color,
    border: ?Color,
    border_width: f32,
    radius: f32,
    scale: f32,
) !void {
    if (rect.width <= 0 or rect.height <= 0) return;

    const render_scale = if (std.math.isFinite(scale) and scale > 0) scale else 1;
    const width = @max(1, @as(usize, @intFromFloat(@ceil(rect.width * render_scale))));
    const height = @max(1, @as(usize, @intFromFloat(@ceil(rect.height * render_scale))));
    const scaled_radius = @max(0, radius * render_scale);

    if (background.a > 0) {
        const cache_key = roundedRectCacheKey(width, height, scaled_radius, null);
        const alpha = if (display_list.cachedAlphaImage(cache_key, @intCast(width), @intCast(height))) |cached|
            cached
        else
            try roundedRectAlpha(allocator, width, height, scaled_radius, null);
        try display_list.alphaImage(allocator, rect, @intCast(width), @intCast(height), @constCast(alpha), background, cache_key);
    }

    if (border) |border_color| {
        const stroke_width = @min(@max(0, border_width * render_scale), @min(@as(f32, @floatFromInt(width)), @as(f32, @floatFromInt(height))) / 2);
        if (stroke_width > 0) {
            const cache_key = roundedRectCacheKey(width, height, scaled_radius, stroke_width);
            const alpha = if (display_list.cachedAlphaImage(cache_key, @intCast(width), @intCast(height))) |cached|
                cached
            else
                try roundedRectAlpha(allocator, width, height, scaled_radius, stroke_width);
            try display_list.alphaImage(allocator, rect, @intCast(width), @intCast(height), @constCast(alpha), border_color, cache_key);
        }
    }
}

/// Rasterizes an antialiased rounded-rect coverage mask with z2d. A fill
/// covers the whole shape; with stroke_width set, only the border band
/// between the outer rect and an inset inner rect is covered (even-odd fill
/// of two nested subpaths).
fn roundedRectAlpha(allocator: std.mem.Allocator, width: usize, height: usize, radius: f32, stroke_width: ?f32) ![]u8 {
    std.debug.assert(width > 0 and height > 0);
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);

    var surface = try z2d.Surface.init(.image_surface_alpha8, allocator, @intCast(width), @intCast(height));
    defer surface.deinit(allocator);

    var path: z2d.Path = .empty;
    defer path.deinit(allocator);

    try appendRoundedRectPath(&path, allocator, 0, 0, w, h, radius);
    if (stroke_width) |stroke| {
        const inset: f64 = stroke;
        const inner_width = w - inset * 2;
        const inner_height = h - inset * 2;
        if (inner_width > 0 and inner_height > 0) {
            try appendRoundedRectPath(&path, allocator, inset, inset, inner_width, inner_height, @max(0, radius - stroke));
        }
    }

    const pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .{ .alpha8 = .{ .a = 255 } } } };
    try z2d.painter.fill(allocator, &surface, &pattern, path.nodes.items, .{ .fill_rule = .even_odd });

    const alpha = try allocator.alloc(u8, width * height);
    for (surface.image_surface_alpha8.buf, alpha) |pixel, *value| value.* = pixel.a;
    return alpha;
}

fn appendRoundedRectPath(path: *z2d.Path, allocator: std.mem.Allocator, x: f64, y: f64, width: f64, height: f64, radius: f32) !void {
    const r = @min(@as(f64, radius), @min(width, height) / 2);
    if (r <= 0) {
        try path.moveTo(allocator, x, y);
        try path.lineTo(allocator, x + width, y);
        try path.lineTo(allocator, x + width, y + height);
        try path.lineTo(allocator, x, y + height);
        try path.close(allocator);
        return;
    }

    const half_pi = std.math.pi / 2.0;
    // The moveTo starts a fresh subpath; each arc connects to the previous
    // one with the straight edge segment.
    try path.moveTo(allocator, x + r, y);
    try path.arc(allocator, x + width - r, y + r, r, -half_pi, 0);
    try path.arc(allocator, x + width - r, y + height - r, r, 0, half_pi);
    try path.arc(allocator, x + r, y + height - r, r, half_pi, std.math.pi);
    try path.arc(allocator, x + r, y + r, r, std.math.pi, 3 * half_pi);
    try path.close(allocator);
}

fn roundedRectCacheKey(width: usize, height: usize, radius: f32, stroke_width: ?f32) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update("rounded-rect");
    hasher.update(std.mem.asBytes(&width));
    hasher.update(std.mem.asBytes(&height));
    hasher.update(std.mem.asBytes(&radius));
    if (stroke_width) |value| hasher.update(std.mem.asBytes(&value));
    return hasher.final();
}

pub fn hitTestButton(node: *const RenderNode, point: Point) ?[]const u8 {
    return if (hitTestClick(node, point)) |hit| hit.id else null;
}

pub const ClickHit = struct {
    id: []const u8,
    handler: HandlerRef,
    activation: Widget.ClickActivation = .release,
};

pub const FocusTarget = struct {
    id: []const u8,
    kind: Kind,
    handler: ?HandlerRef = null,
    scope_id: ?[]const u8 = null,
    modal_scope_id: ?[]const u8 = null,
    autofocus: bool = false,
    skip_traversal: bool = false,
    can_request_focus: bool = true,
    focus_change_handler: ?HandlerRef = null,

    pub const Kind = enum {
        text_field,
        gesture_detector,
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
        .text_field => if (node.focus_id) |id| try targets.append(allocator, .{ .id = id, .kind = .text_field, .scope_id = active_scope_id, .modal_scope_id = active_modal_scope_id, .autofocus = node.autofocus }),
        .focus => if (node.focus_id) |id| try targets.append(allocator, .{
            .id = id,
            .kind = .focus,
            .scope_id = active_scope_id,
            .modal_scope_id = active_modal_scope_id,
            .autofocus = node.autofocus,
            .skip_traversal = node.skip_traversal,
            .can_request_focus = node.can_request_focus,
            .focus_change_handler = node.focus_change_handler,
        }),
        .gesture_detector => if (node.handler) |handler| {
            if (node.clickable_id) |id| try targets.append(allocator, .{ .id = id, .kind = .gesture_detector, .handler = handler, .scope_id = active_scope_id, .modal_scope_id = active_modal_scope_id });
        },
        else => {},
    }
    for (node.children) |child| {
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
        .text_field => if (node.focus_id) |focus_id| {
            if (std.mem.eql(u8, focus_id, id)) return .{ .id = focus_id, .kind = .text_field, .scope_id = active_scope_id, .modal_scope_id = active_modal_scope_id, .autofocus = node.autofocus };
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
                .focus_change_handler = node.focus_change_handler,
            };
        },
        .gesture_detector => if (node.handler) |handler| {
            if (node.clickable_id) |clickable_id| {
                if (std.mem.eql(u8, clickable_id, id)) return .{ .id = clickable_id, .kind = .gesture_detector, .handler = handler, .scope_id = active_scope_id, .modal_scope_id = active_modal_scope_id };
            }
        },
        else => {},
    }
    for (node.children) |child| {
        if (findFocusTargetScoped(child, id, active_scope_id, active_modal_scope_id)) |target| return target;
    }
    return null;
}

pub fn hitTestClick(node: *const RenderNode, point: Point) ?ClickHit {
    if (isViewportKind(node.kind) and !node.rect.contains(point)) return null;
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (hitTestClick(node.children[index], point)) |hit| return hit;
    }

    if (node.kind == .gesture_detector and node.rect.contains(point)) {
        if (!nodeHasHandler(node)) return null;
        return .{
            .id = node.clickable_id orelse return null,
            .handler = node.handler orelse return null,
            .activation = node.click_activation,
        };
    }
    return null;
}

pub fn findClickHitById(node: *const RenderNode, id: []const u8) ?ClickHit {
    if (node.kind == .gesture_detector) {
        if (node.clickable_id) |clickable_id| {
            if (std.mem.eql(u8, clickable_id, id) and nodeHasHandler(node)) return .{
                .id = clickable_id,
                .handler = node.handler orelse return null,
                .activation = node.click_activation,
            };
        }
    }
    for (node.children) |child| {
        if (findClickHitById(child, id)) |hit| return hit;
    }
    return null;
}

fn nodeHasHandler(node: *const RenderNode) bool {
    return node.handler != null;
}

pub fn hitTestTextInput(node: *const RenderNode, point: Point) ?[]const u8 {
    if (isViewportKind(node.kind) and !node.rect.contains(point)) return null;
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (hitTestTextInput(node.children[index], point)) |id| return id;
    }

    if (node.kind == .text_field and node.rect.contains(point)) {
        return node.focus_id;
    }
    return null;
}

pub fn hitTestScroll(node: *const RenderNode, point: Point) ?[]const u8 {
    if (isViewportKind(node.kind) and !node.rect.contains(point)) return null;
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (hitTestScroll(node.children[index], point)) |id| return id;
    }
    if (isViewportKind(node.kind)) return node.scroll_id;
    return null;
}

pub const RevealAdjustment = struct {
    /// Borrowed from the render node; valid until the next layout.
    id: []const u8,
    dx: f32,
    dy: f32,
};

/// Collects the viewport offset increases needed to bring the focus
/// target with the given id into view, innermost viewport first. Returns
/// the target's rect (shifted by the collected adjustments) when found.
pub fn collectRevealAdjustments(
    allocator: std.mem.Allocator,
    node: *const RenderNode,
    id: []const u8,
    out: *std.ArrayList(RevealAdjustment),
) !?Rect {
    const is_target = switch (node.kind) {
        .text_field, .focus => node.focus_id != null and std.mem.eql(u8, node.focus_id.?, id),
        .gesture_detector => node.clickable_id != null and std.mem.eql(u8, node.clickable_id.?, id),
        else => false,
    };
    if (is_target) return node.rect;
    for (node.children) |child| {
        const target_rect = try collectRevealAdjustments(allocator, child, id, out) orelse continue;
        var rect = target_rect;
        if (isViewportKind(node.kind)) {
            if (node.scroll_id) |scroll_id| {
                const dx = revealDelta(rect.x, rect.width, node.rect.x, node.rect.width);
                const dy = revealDelta(rect.y, rect.height, node.rect.y, node.rect.height);
                if (dx != 0 or dy != 0) {
                    try out.append(allocator, .{ .id = scroll_id, .dx = dx, .dy = dy });
                    rect.x -= dx;
                    rect.y -= dy;
                }
            }
        }
        return rect;
    }
    return null;
}

/// Offset increase that reveals [start, start+extent) inside the viewport
/// span: the minimum scroll distance, aligning to the near edge when the
/// target is larger than the viewport.
fn revealDelta(start: f32, extent: f32, viewport_start: f32, viewport_extent: f32) f32 {
    if (start < viewport_start) return start - viewport_start;
    const end = start + extent;
    const viewport_end = viewport_start + viewport_extent;
    if (end > viewport_end) return @min(start - viewport_start, end - viewport_end);
    return 0;
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
        .escape => .escape,
        .up => .up,
        .down => .down,
        .text, .tab => null,
    };
}

/// Keys that never edit text may activate shortcuts even while a text
/// input owns focus; editing keys must keep reaching the input.
pub fn shortcutAllowedWhileEditing(key: ShortcutKey) bool {
    return switch (key) {
        .enter, .escape, .up, .down => true,
        .space, .backspace => false,
    };
}

pub fn findShortcutHandler(element: *const Element, key: ShortcutKey) ?HandlerRef {
    if (element.widget == .shortcuts) {
        for (element.widget.shortcuts.bindings) |binding| {
            if (binding.key == key) return .{ .document = element.document_id, .handler = binding.handler };
        }
    }
    for (element.children) |*child| {
        if (findShortcutHandler(child, key)) |handler| return handler;
    }
    return null;
}

pub fn findFocusedShortcutHandler(element: *const Element, focused_id: []const u8, key: ShortcutKey) ?HandlerRef {
    var nearest: ?HandlerRef = null;
    return findFocusedShortcutHandlerScoped(element, focused_id, key, &nearest);
}

fn findFocusedShortcutHandlerScoped(element: *const Element, focused_id: []const u8, key: ShortcutKey, nearest: *?HandlerRef) ?HandlerRef {
    const previous = nearest.*;
    if (element.widget == .shortcuts) {
        for (element.widget.shortcuts.bindings) |binding| {
            if (binding.key == key) {
                nearest.* = .{ .document = element.document_id, .handler = binding.handler };
                break;
            }
        }
    }
    defer nearest.* = previous;

    if (elementIsFocused(element, focused_id)) return nearest.*;
    for (element.children) |*child| {
        if (findFocusedShortcutHandlerScoped(child, focused_id, key, nearest)) |handler| return handler;
    }
    return null;
}

fn elementIsFocused(element: *const Element, focused_id: []const u8) bool {
    return switch (element.widget) {
        .filled_button => |button_widget| button_widget.handler != null and std.mem.eql(u8, button_widget.id, focused_id),
        .gesture_detector => |clickable_widget| std.mem.eql(u8, clickable_widget.id, focused_id),
        .focus => |focus_widget| std.mem.eql(u8, focus_widget.node.id, focused_id),
        .text_field => |input_widget| std.mem.eql(u8, input_widget.focus_node.id, focused_id),
        else => false,
    };
}

fn ensureRenderNode(allocator: std.mem.Allocator, element: *Element) !*RenderNode {
    if (element.render_node) |node| return node;
    const node = try allocator.create(RenderNode);
    node.* = .{ .kind = .spacer, .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
    element.render_node = node;
    return node;
}

/// Replaces the node payload in place, preserving node identity and its
/// child slice. Payload strings are borrowed from the element's widget,
/// which owns them and strictly outlives the node.
fn commitRenderNode(node: *RenderNode, value: RenderNode) void {
    std.debug.assert(value.children.len == 0);
    const children = node.children;
    const constraints = node.constraints;
    // Non-painting wrappers only damage when their bounds change (covering
    // vacated regions); painted nodes always damage since their payload may
    // have changed. Ancestors on a dirty path re-commit with identical
    // geometry and must not inflate the damage to their full bounds.
    const rect_changed = !std.meta.eql(node.rect, value.rect);
    const paints = switch (value.kind) {
        .container, .text, .text_field, .image, .icon => true,
        else => false,
    };
    var damage = node.damage;
    if (rect_changed or paints) {
        damage = unionDamage(unionDamage(damage, node.rect), value.rect);
    }
    node.* = value;
    node.children = children;
    node.constraints = constraints;
    node.damage = damage;
    node.needs_layout = false;
}

fn unionDamage(damage: ?Rect, rect: Rect) ?Rect {
    if (rect.isEmpty()) return damage;
    const existing = damage orelse return rect;
    const x0 = @min(existing.x, rect.x);
    const y0 = @min(existing.y, rect.y);
    const x1 = @max(existing.x + existing.width, rect.x + rect.width);
    const y1 = @max(existing.y + existing.height, rect.y + rect.height);
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

/// Collects and clears the damage accumulated across the tree since the
/// last collection. Null means nothing changed.
pub fn collectDamage(node: *RenderNode) ?Rect {
    var damage = node.damage;
    node.damage = null;
    for (node.children) |child| {
        if (collectDamage(child)) |child_damage| {
            damage = unionDamage(damage, child_damage);
        }
    }
    return damage;
}

fn ensureChildSlice(allocator: std.mem.Allocator, node: *RenderNode, count: usize) ![]*RenderNode {
    if (node.children.len != count) {
        allocator.free(node.children);
        node.children = &.{};
        node.children = try allocator.alloc(*RenderNode, count);
    }
    return node.children;
}

fn moveNode(node: *RenderNode, x: f32, y: f32) void {
    if (node.rect.x == x and node.rect.y == y) return;
    const dx = x - node.rect.x;
    const dy = y - node.rect.y;
    node.damage = unionDamage(node.damage, node.rect);
    node.rect.x = x;
    node.rect.y = y;
    node.damage = unionDamage(node.damage, node.rect);
    translateChildren(node, dx, dy);
}

/// Lays out an element subtree into its retained render node, mutating
/// geometry in place. Nodes are created lazily and live as long as their
/// element; repeated layouts reuse them.
///
/// A clean subtree re-laid out with identical constraints is skipped
/// entirely: its cached geometry is still valid, so at most it is
/// translated to a new origin.
fn layoutElement(allocator: std.mem.Allocator, element: *Element, constraints: Constraints, origin: Point, measurer: TextMeasurer) LayoutError!*RenderNode {
    const node = try ensureRenderNode(allocator, element);
    if (!node.needs_layout and std.meta.eql(node.constraints, constraints)) {
        if (node.rect.x != origin.x or node.rect.y != origin.y) moveNode(node, origin.x, origin.y);
        return node;
    }
    try layoutElementInto(allocator, element, node, constraints, origin, measurer);
    node.constraints = constraints;
    return node;
}

/// Marks the element's retained render node for relayout. Called wherever
/// an element's widget (or a descendant's) may have changed.
fn markElementLayoutDirty(element: *Element) void {
    if (element.render_node) |node| node.needs_layout = true;
}

fn layoutWrapper(
    allocator: std.mem.Allocator,
    element: *Element,
    node: *RenderNode,
    comptime kind: RenderNode.Kind,
    constraints: Constraints,
    origin: Point,
    measurer: TextMeasurer,
) LayoutError!void {
    const child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
    const children = try ensureChildSlice(allocator, node, 1);
    children[0] = child;
    commitRenderNode(node, .{
        .kind = kind,
        .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
    });
}

fn layoutElementInto(
    allocator: std.mem.Allocator,
    element: *Element,
    node: *RenderNode,
    constraints: Constraints,
    origin: Point,
    measurer: TextMeasurer,
) LayoutError!void {
    switch (element.widget) {
        .shortcuts => try layoutWrapper(allocator, element, node, .shortcuts, constraints, origin, measurer),
        .default_text_style => try layoutWrapper(allocator, element, node, .default_text_style, constraints, origin, measurer),
        .text => |text_widget| {
            const style: ResolvedTextStyle = .{ .color = text_widget.color orelse colors.ink, .font_size = text_widget.font_size orelse 16 };
            const measured = try measurer.measureText(text_widget.value, style);
            const size_value = constraints.clamp(measured);
            _ = try ensureChildSlice(allocator, node, 0);
            commitRenderNode(node, .{
                .kind = .text,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .text = text_widget.value,
                .text_style = style,
                .foreground = style.color,
            });
        },
        .spacer => {
            _ = try ensureChildSlice(allocator, node, 0);
            commitRenderNode(node, .{
                .kind = .spacer,
                .rect = .{ .x = origin.x, .y = origin.y, .width = 0, .height = 0 },
            });
        },
        .sized_box => |sized_widget| {
            const child_constraints = constrainSized(constraints, sized_widget);
            const child = try layoutElement(allocator, &element.children[0], child_constraints, origin, measurer);
            const width = @min(constraints.max_width, @max(sized_widget.min_width, sized_widget.width orelse child.rect.width));
            const height = @min(constraints.max_height, @max(sized_widget.min_height, sized_widget.height orelse child.rect.height));
            moveNode(child, origin.x, origin.y);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .sized_box,
                .rect = .{ .x = origin.x, .y = origin.y, .width = width, .height = height },
            });
        },
        .container => |box_widget| {
            const child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            const width = @min(constraints.max_width, @max(box_widget.min_width, child.rect.width));
            const height = @min(constraints.max_height, @max(box_widget.min_height, child.rect.height));
            moveNode(
                child,
                origin.x + alignedOffset(box_widget.horizontal_align, width, child.rect.width),
                origin.y + alignedOffset(box_widget.vertical_align, height, child.rect.height),
            );
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .container,
                .rect = .{ .x = origin.x, .y = origin.y, .width = width, .height = height },
                .background = box_widget.background,
                .box_border = box_widget.border,
                .box_border_width = box_widget.border_width,
                .box_radius = box_widget.radius,
            });
        },
        .filled_button => |button_widget| {
            const child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .gesture_detector,
                .rect = child.rect,
                .clickable_id = button_widget.id,
                .handler = if (button_widget.handler) |handler| .{ .document = element.document_id, .handler = handler } else null,
                .click_activation = button_widget.activation,
            });
        },
        .gesture_detector => |clickable_widget| {
            const child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .gesture_detector,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .clickable_id = clickable_widget.id,
                .handler = .{ .document = element.document_id, .handler = clickable_widget.handler },
                .click_activation = clickable_widget.activation,
            });
        },
        .focus => |focus_widget| {
            const child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .focus,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .focus_id = focus_widget.node.id,
                .focused = element.focused,
                .autofocus = focus_widget.autofocus,
                .skip_traversal = focus_widget.skip_traversal,
                .can_request_focus = focus_widget.can_request_focus,
                .focus_change_handler = if (focus_widget.on_focus_change) |handler| .{ .document = element.document_id, .handler = handler } else null,
            });
        },
        .focus_scope => |focus_scope_widget| {
            const child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .focus_scope,
                .rect = .{ .x = origin.x, .y = origin.y, .width = child.rect.width, .height = child.rect.height },
                .focus_scope_id = focus_scope_widget.id,
                .modal_focus_scope = focus_scope_widget.modal,
            });
        },
        .single_child_scroll_view => |scroll_widget| {
            const state = scrollState(element);
            const child = try layoutElement(allocator, &element.children[0], scrollChildConstraints(constraints, scroll_widget.axes), .{
                .x = origin.x - state.offset_x,
                .y = origin.y - state.offset_y,
            }, measurer);
            const width = @min(constraints.max_width, child.rect.width);
            const height = @min(constraints.max_height, child.rect.height);
            state.offset_x = std.math.clamp(state.offset_x, 0, @max(0, child.rect.width - width));
            state.offset_y = std.math.clamp(state.offset_y, 0, @max(0, child.rect.height - height));
            moveNode(child, origin.x - state.offset_x, origin.y - state.offset_y);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .single_child_scroll_view,
                .rect = .{ .x = origin.x, .y = origin.y, .width = width, .height = height },
                .scroll_id = scroll_widget.id,
                .scroll_content = child.rect.size(),
                .scroll_offset = .{ .x = state.offset_x, .y = state.offset_y },
            });
        },
        .text_field => |input_widget| {
            const value = textInputState(element).text.items;
            const text_value = if (value.len > 0) value else input_widget.placeholder;
            const style: ResolvedTextStyle = .{ .color = input_widget.foreground, .font_size = 16 };
            const measured = try measurer.measureText(text_value, style);
            const value_size = try measurer.measureText(value, style);
            const fill_width = if (std.math.isFinite(constraints.max_width)) constraints.max_width else 0;
            const requested = Size{
                .width = @max(input_min_width, @max(measured.width + input_widget.padding_x * 2, fill_width)),
                .height = measured.height + input_widget.padding_y * 2,
            };
            const size_value = constraints.clamp(requested);
            _ = try ensureChildSlice(allocator, node, 0);
            commitRenderNode(node, .{
                .kind = .text_field,
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .text = textInputState(element).text.items,
                .text_input_id = input_widget.id,
                .focus_id = input_widget.focus_node.id,
                .autofocus = input_widget.autofocus,
                .text_style = style,
                .foreground = input_widget.foreground,
                .background = input_widget.background,
                .placeholder = input_widget.placeholder,
                .border = input_widget.border,
                .focused_border = input_widget.focused_border,
                .placeholder_foreground = input_widget.placeholder_foreground,
                .padding_x = input_widget.padding_x,
                .padding_y = input_widget.padding_y,
                .box_radius = input_widget.radius,
                .focused = element.focused,
                .caret_x = origin.x + input_widget.padding_x + value_size.width,
            });
        },
        .padding => |padding_widget| {
            const child = try layoutElement(allocator, &element.children[0], constraints.inset(padding_widget.insets), .{
                .x = origin.x + padding_widget.insets.left,
                .y = origin.y + padding_widget.insets.top,
            }, measurer);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .padding,
                .rect = .{
                    .x = origin.x,
                    .y = origin.y,
                    .width = @min(child.rect.width + padding_widget.insets.horizontal(), constraints.max_width),
                    .height = @min(child.rect.height + padding_widget.insets.vertical(), constraints.max_height),
                },
            });
        },
        .flexible => {
            // Outside a row or column a flexible wrapper is a passthrough;
            // inside one, layoutLinearElements supplies the share as the
            // constraints and enforces tight fit on the result.
            const child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .flexible,
                .rect = child.rect,
            });
        },
        .center => {
            const child = try layoutElement(allocator, &element.children[0], constraints, origin, measurer);
            // An unbounded axis centers around the child's own extent.
            const avail_width = if (std.math.isFinite(constraints.max_width)) constraints.max_width else child.rect.width;
            const avail_height = if (std.math.isFinite(constraints.max_height)) constraints.max_height else child.rect.height;
            moveNode(
                child,
                origin.x + @max(0, avail_width - child.rect.width) / 2,
                origin.y + @max(0, avail_height - child.rect.height) / 2,
            );
            const children = try ensureChildSlice(allocator, node, 1);
            children[0] = child;
            commitRenderNode(node, .{
                .kind = .center,
                .rect = .{ .x = origin.x, .y = origin.y, .width = avail_width, .height = avail_height },
            });
        },
        .column => |column_widget| try layoutLinearElements(allocator, node, .column, element.children, column_widget.gap, column_widget.cross_align, column_widget.main_align, constraints, origin, measurer),
        .row => |row_widget| try layoutLinearElements(allocator, node, .row, element.children, row_widget.gap, row_widget.cross_align, row_widget.main_align, constraints, origin, measurer),
        .image, .icon => {
            const render_object = element.render_object orelse return error.MissingRenderObject;
            const measured = try render_object.layout(.{ .constraints = constraints, .text_measurer = measurer });
            const size_value = constraints.clamp(measured);
            _ = try ensureChildSlice(allocator, node, 0);
            commitRenderNode(node, .{
                .kind = switch (element.kind) {
                    .image => .image,
                    .icon => .icon,
                    else => unreachable,
                },
                .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
                .render_object = render_object,
            });
        },
    }
}

fn mainExtent(comptime kind: RenderNode.Kind, child: *const RenderNode) f32 {
    return switch (kind) {
        .row => child.rect.width,
        .column => child.rect.height,
        else => unreachable,
    };
}

fn crossExtent(comptime kind: RenderNode.Kind, child: *const RenderNode) f32 {
    return switch (kind) {
        .row => child.rect.height,
        .column => child.rect.width,
        else => unreachable,
    };
}

fn setMainExtent(comptime kind: RenderNode.Kind, child: *RenderNode, value: f32) void {
    switch (kind) {
        .row => child.rect.width = value,
        .column => child.rect.height = value,
        else => unreachable,
    }
}

fn layoutLinearElements(
    allocator: std.mem.Allocator,
    node: *RenderNode,
    comptime kind: RenderNode.Kind,
    elements: []Element,
    gap: f32,
    cross_align: Widget.CrossAxisAlignment,
    main_align: Widget.MainAxisAlignment,
    constraints: Constraints,
    origin: Point,
    measurer: TextMeasurer,
) LayoutError!void {
    std.debug.assert(kind == .row or kind == .column);

    const children = try ensureChildSlice(allocator, node, elements.len);

    const total_gap = if (elements.len > 0) gap * @as(f32, @floatFromInt(elements.len - 1)) else 0;
    var fixed_main: f32 = 0;
    var cross: f32 = 0;
    var total_flex: f32 = 0;

    // Pass 1: intrinsic children establish the fixed extent; spacers and
    // flexible children only contribute their flex factors.
    for (elements, 0..) |*child_element, index| {
        switch (child_element.widget) {
            .spacer => |spacer_widget| {
                total_flex += spacer_widget.flex;
                const spacer_node = try ensureRenderNode(allocator, child_element);
                commitRenderNode(spacer_node, .{
                    .kind = .spacer,
                    .rect = .{ .x = origin.x, .y = origin.y, .width = 0, .height = 0 },
                });
                spacer_node.constraints = constraints;
                children[index] = spacer_node;
            },
            .flexible => |flexible_widget| total_flex += flexible_widget.flex,
            else => {
                // Tentatively lay the child at its previous position; the
                // positioning pass moves it to its final slot. This keeps
                // unchanged children in place instead of thrashing their
                // damage via parent-origin moves.
                const tentative_origin: Point = if (child_element.render_node) |existing|
                    .{ .x = existing.rect.x, .y = existing.rect.y }
                else
                    origin;
                children[index] = try layoutElement(allocator, child_element, constraints, tentative_origin, measurer);
                fixed_main += mainExtent(kind, children[index]);
                cross = @max(cross, crossExtent(kind, children[index]));
            },
        }
    }

    const max_main = switch (kind) {
        .row => constraints.max_width,
        .column => constraints.max_height,
        else => unreachable,
    };
    const bounded = std.math.isFinite(max_main);
    const spare = if (bounded) @max(0, max_main - fixed_main - total_gap) else 0;

    // Pass 2: flexible children split the spare space in proportion to
    // their factors. A tight fit fills its whole share even when the
    // child lays out smaller, mirroring the cross-axis stretch mechanism.
    for (elements, 0..) |*child_element, index| {
        if (child_element.widget != .flexible) continue;
        const flexible_widget = child_element.widget.flexible;
        const share = if (total_flex > 0) spare * flexible_widget.flex / total_flex else 0;
        const child_constraints: Constraints = switch (kind) {
            .row => .{ .max_width = share, .max_height = constraints.max_height },
            .column => .{ .max_width = constraints.max_width, .max_height = share },
            else => unreachable,
        };
        const tentative_origin: Point = if (child_element.render_node) |existing|
            .{ .x = existing.rect.x, .y = existing.rect.y }
        else
            origin;
        children[index] = try layoutElement(allocator, child_element, child_constraints, tentative_origin, measurer);
        if (flexible_widget.fit == .tight) {
            setMainExtent(kind, children[index], share);
            if (children[index].children.len == 1) setMainExtent(kind, children[index].children[0], share);
        }
        cross = @max(cross, crossExtent(kind, children[index]));
    }

    var content_main: f32 = total_gap;
    for (elements, 0..) |*child_element, index| {
        if (child_element.widget == .spacer) {
            content_main += if (total_flex > 0) spare * child_element.widget.spacer.flex / total_flex else 0;
        } else {
            content_main += mainExtent(kind, children[index]);
        }
    }

    // Flex children or a non-start alignment claim the whole main axis;
    // otherwise the container shrink-wraps its content as before.
    const wants_full = bounded and (total_flex > 0 or main_align != .start);
    const main_size = if (wants_full) max_main else content_main;
    const leftover = @max(0, main_size - content_main);

    var lead: f32 = 0;
    var extra_between: f32 = 0;
    const count: f32 = @floatFromInt(elements.len);
    switch (main_align) {
        .start => {},
        .center => lead = leftover / 2,
        .end => lead = leftover,
        .space_between => if (elements.len > 1) {
            extra_between = leftover / (count - 1);
        },
        .space_around => if (elements.len > 0) {
            lead = leftover / count / 2;
            extra_between = leftover / count;
        },
        .space_evenly => if (elements.len > 0) {
            lead = leftover / (count + 1);
            extra_between = leftover / (count + 1);
        },
    }

    // Positioning pass.
    var cursor: Point = switch (kind) {
        .row => .{ .x = origin.x + lead, .y = origin.y },
        .column => .{ .x = origin.x, .y = origin.y + lead },
        else => unreachable,
    };
    for (elements, 0..) |*child_element, index| {
        const child = children[index];
        if (child_element.widget == .spacer and total_flex > 0) {
            const spacer_main = spare * child_element.widget.spacer.flex / total_flex;
            child.rect = switch (kind) {
                .row => .{ .x = cursor.x, .y = origin.y, .width = spacer_main, .height = cross },
                .column => .{ .x = origin.x, .y = cursor.y, .width = cross, .height = spacer_main },
                else => unreachable,
            };
        } else {
            const aligned_cross = alignedCrossOffset(kind, cross_align, cross, child);
            const new_x = switch (kind) {
                .row => cursor.x,
                .column => origin.x + aligned_cross,
                else => unreachable,
            };
            const new_y = switch (kind) {
                .row => origin.y + aligned_cross,
                .column => cursor.y,
                else => unreachable,
            };
            moveNode(child, new_x, new_y);
            if (cross_align == .stretch) switch (kind) {
                .row => child.rect.height = cross,
                .column => child.rect.width = cross,
                else => unreachable,
            };
        }

        switch (kind) {
            .row => cursor.x += child.rect.width + gap + extra_between,
            .column => cursor.y += child.rect.height + gap + extra_between,
            else => unreachable,
        }
    }

    const size_value = switch (kind) {
        .row => constraints.clamp(.{ .width = main_size, .height = cross }),
        .column => constraints.clamp(.{ .width = cross, .height = main_size }),
        else => unreachable,
    };
    commitRenderNode(node, .{
        .kind = kind,
        .rect = .{ .x = origin.x, .y = origin.y, .width = size_value.width, .height = size_value.height },
    });
}

fn constrainSized(parent: Constraints, sized_widget: Widget.SizedBox) Constraints {
    const max_width = sized_widget.width orelse sized_widget.max_width orelse parent.max_width;
    const max_height = sized_widget.height orelse sized_widget.max_height orelse parent.max_height;
    return .{
        .max_width = @max(0, @min(parent.max_width, @max(sized_widget.min_width, max_width))),
        .max_height = @max(0, @min(parent.max_height, @max(sized_widget.min_height, max_height))),
    };
}

fn alignedCrossOffset(kind: RenderNode.Kind, alignment: Widget.CrossAxisAlignment, cross: f32, child: *const RenderNode) f32 {
    const child_cross = switch (kind) {
        .row => child.rect.height,
        .column => child.rect.width,
        else => unreachable,
    };
    return switch (alignment) {
        .start, .stretch => 0,
        .center => @max(0, cross - child_cross) / 2,
        .end => @max(0, cross - child_cross),
    };
}

fn alignedOffset(alignment: Widget.Alignment, outer: f32, inner: f32) f32 {
    return switch (alignment) {
        .start => 0,
        .center => @max(0, outer - inner) / 2,
        .end => @max(0, outer - inner),
    };
}

fn fixedMeasureText(value: []const u8, style: ResolvedTextStyle) Size {
    return .{ .width = @as(f32, @floatFromInt(value.len)) * style.font_size * text_width_ratio, .height = style.font_size };
}

fn translateChildren(node: *RenderNode, dx: f32, dy: f32) void {
    for (node.children) |child| {
        child.rect.x += dx;
        child.rect.y += dy;
        translateChildren(child, dx, dy);
    }
}

test "widgets.text creates unkeyed text widget" {
    const widget = widgets.text("x");
    try std.testing.expect(widget == .text);
    try std.testing.expectEqual(@as(?[]const u8, null), widget.text.key);
}

test "keyed reconciliation preserves element state across reorder" {
    const constraints: Constraints = .{ .max_width = 400, .max_height = 100 };
    const first_children = [_]Widget{
        .{ .text_field = .{ .key = "a", .id = "a", .focus_node = .named("a"), .value = "alpha", .placeholder = "" } },
        .{ .text_field = .{ .key = "b", .id = "b", .focus_node = .named("b"), .value = "beta", .placeholder = "" } },
    };
    const first: Widget = .{ .row = .{ .children = &first_children } };
    var element = try buildElementTree(std.testing.allocator, &first, constraints);
    defer destroyElementTree(std.testing.allocator, &element);

    const a_state = textInputState(&element.children[0]);
    a_state.text.clearRetainingCapacity();
    try a_state.text.appendSlice(std.testing.allocator, "edited");

    const second_children = [_]Widget{
        .{ .text_field = .{ .key = "b", .id = "b", .focus_node = .named("b"), .value = "new beta", .placeholder = "" } },
        .{ .text_field = .{ .key = "a", .id = "a", .focus_node = .named("a"), .value = "new alpha", .placeholder = "" } },
    };
    const second: Widget = .{ .row = .{ .children = &second_children } };
    try updateElementTree(std.testing.allocator, &element, &second, constraints);

    try std.testing.expectEqual(a_state, textInputState(&element.children[1]));
    try std.testing.expectEqualStrings("edited", textInputState(&element.children[1]).text.items);
}

test "clickable box paints base and hover backgrounds" {
    const label = widgets.text("Increment");
    const padded: Widget = .{ .padding = .{
        .insets = .{ .left = 12, .top = 8, .right = 12, .bottom = 8 },
        .child = &label,
    } };
    const surface: Widget = .{ .container = .{
        .child = &padded,
        .background = colors.slate3,
    } };
    const clickable: Widget = .{ .gesture_detector = .{
        .id = "increment",
        .handler = 1,
        .child = &surface,
        .hover_style = .{ .background = colors.slate7 },
    } };
    const constraints: Constraints = .{ .max_width = 400, .max_height = 100 };
    var scope: BuildScope = .{};
    var element = try buildElementTreeScoped(std.testing.allocator, &scope, &clickable, constraints);
    defer destroyElementTree(std.testing.allocator, &element);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var log_backend: LogBackend = .{ .writer = &output.writer };
    var display_list: DisplayList = .{};
    defer display_list.deinit(std.testing.allocator);

    var render_root = try buildRenderTreeFromElement(std.testing.allocator, &element, constraints, log_backend.backend());
    try paint(std.testing.allocator, render_root, &display_list);
    try std.testing.expect(displayListHasColor(&display_list, colors.slate3));

    scope.interaction.hovered_id = "increment";
    _ = try refreshInteractionElements(std.testing.allocator, &scope, &element, constraints, &.{"increment"});
    render_root = try buildRenderTreeFromElement(std.testing.allocator, &element, constraints, log_backend.backend());
    display_list.clearRetainingCapacity(std.testing.allocator);
    try paint(std.testing.allocator, render_root, &display_list);
    try std.testing.expect(displayListHasColor(&display_list, colors.slate7));
}

test "semantic button resolves light dark and hover theme colors" {
    const label: Widget = .{ .text = .{ .value = "Increment", .role = .label } };
    const button: Widget = .{ .filled_button = .{
        .id = "increment",
        .handler = 1,
        .child = &label,
    } };
    const constraints: Constraints = .{ .max_width = 400, .max_height = 100 };
    var scope: BuildScope = .{ .theme = .light };
    var element = try buildElementTreeScoped(std.testing.allocator, &scope, &button, constraints);
    defer destroyElementTree(std.testing.allocator, &element);

    try std.testing.expectEqual(ColorScheme.light.primary, element.children[0].widget.container.background);
    try std.testing.expectEqual(ColorScheme.light.on_primary, element.children[0].children[0].children[0].children[0].widget.text.color.?);

    scope.interaction.hovered_id = "increment";
    _ = try refreshInteractionElements(std.testing.allocator, &scope, &element, constraints, &.{"increment"});
    try std.testing.expectEqual(ColorScheme.light.primary_container, element.children[0].widget.container.background);

    scope.theme = .dark;
    scope.interaction.hovered_id = null;
    try updateElementTreeScoped(std.testing.allocator, &scope, &element, &button, constraints);
    try std.testing.expectEqual(ColorScheme.dark.primary, element.children[0].widget.container.background);
    try std.testing.expectEqual(ColorScheme.dark.on_primary, element.children[0].children[0].children[0].children[0].widget.text.color.?);
}

test "semantic button restores hover pressed focus disabled and keyboard behavior" {
    const label: Widget = .{ .text = .{ .value = "Action", .role = .label } };
    const enabled_button: Widget = .{ .filled_button = .{
        .id = "action",
        .handler = 7,
        .child = &label,
    } };
    const theme: Theme = .{
        .color_scheme = .light,
        .button_theme = .{
            .background = colors.blue9,
            .foreground = colors.white,
            .hover_background = colors.black,
            .hover_foreground = colors.slate2,
            .pressed_background = colors.red9,
            .focused_border = colors.slate12,
            .disabled_background = colors.slate7,
            .disabled_foreground = colors.slate11,
        },
    };
    const constraints: Constraints = .{ .max_width = 400, .max_height = 100 };
    var scope: BuildScope = .{ .theme = theme };
    var element = try buildElementTreeScoped(std.testing.allocator, &scope, &enabled_button, constraints);
    defer destroyElementTree(std.testing.allocator, &element);

    try std.testing.expectEqual(colors.blue9, element.children[0].widget.container.background);
    try std.testing.expectEqual(colors.white, element.children[0].children[0].children[0].children[0].widget.text.color.?);

    scope.interaction.hovered_id = "action";
    _ = try refreshInteractionElements(std.testing.allocator, &scope, &element, constraints, &.{"action"});
    try std.testing.expectEqual(colors.black, element.children[0].widget.container.background);
    try std.testing.expectEqual(colors.slate2, element.children[0].children[0].children[0].children[0].widget.text.color.?);

    scope.interaction.pressed_id = "action";
    _ = try refreshInteractionElements(std.testing.allocator, &scope, &element, constraints, &.{"action"});
    try std.testing.expectEqual(colors.red9, element.children[0].widget.container.background);

    scope.interaction.focused_id = "action";
    try updateElementTreeScoped(std.testing.allocator, &scope, &element, &enabled_button, constraints);
    try std.testing.expectEqual(colors.slate12, element.children[0].widget.container.border.?);

    var root = try layoutElement(std.testing.allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expect(hitTestClick(root, .{ .x = 1, .y = 1 }) != null);
    const enabled_targets = try collectFocusTargets(std.testing.allocator, root);
    defer std.testing.allocator.free(enabled_targets);
    try std.testing.expectEqual(@as(usize, 1), enabled_targets.len);
    try std.testing.expectEqualStrings("action", enabled_targets[0].id);

    const disabled_button: Widget = .{ .filled_button = .{
        .id = "action",
        .child = &label,
    } };
    try updateElementTreeScoped(std.testing.allocator, &scope, &element, &disabled_button, constraints);
    try std.testing.expectEqual(colors.slate7, element.children[0].widget.container.background);
    try std.testing.expectEqual(colors.slate11, element.children[0].children[0].children[0].children[0].widget.text.color.?);
    try std.testing.expectEqual(@as(?Color, null), element.children[0].widget.container.border);

    root = try layoutElement(std.testing.allocator, &element, constraints, .{ .x = 0, .y = 0 }, .fixed);
    try std.testing.expect(hitTestClick(root, .{ .x = 1, .y = 1 }) == null);
    const disabled_targets = try collectFocusTargets(std.testing.allocator, root);
    defer std.testing.allocator.free(disabled_targets);
    try std.testing.expectEqual(@as(usize, 0), disabled_targets.len);
}

fn displayListHasColor(display_list: *const DisplayList, color: Color) bool {
    for (display_list.commands.items) |command| switch (command) {
        .fill_rect => |fill| if (fill.color == color) return true,
        .alpha_image => |image| if (image.color == color) return true,
        else => {},
    };
    return false;
}
