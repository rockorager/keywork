//! Platform-neutral UI value types.

const std = @import("std");

pub const Color = packed struct(u32) {
    b: u8,
    g: u8,
    r: u8,
    a: u8,

    pub fn argb(a: u8, r: u8, g: u8, b: u8) Color {
        return .{ .a = a, .r = r, .g = g, .b = b };
    }

    pub fn blendOver(self: Color, destination: Color, coverage: u8) Color {
        const source_alpha = (@as(u32, self.a) * coverage + 127) / 255;
        const inverse_alpha = 255 - source_alpha;
        return .{
            .a = @intCast(source_alpha + (@as(u32, destination.a) * inverse_alpha + 127) / 255),
            .r = @intCast((@as(u32, self.r) * source_alpha + @as(u32, destination.r) * inverse_alpha + 127) / 255),
            .g = @intCast((@as(u32, self.g) * source_alpha + @as(u32, destination.g) * inverse_alpha + 127) / 255),
            .b = @intCast((@as(u32, self.b) * source_alpha + @as(u32, destination.b) * inverse_alpha + 127) / 255),
        };
    }
};

pub const colors = struct {
    pub const transparent: Color = Color.argb(0x00, 0x00, 0x00, 0x00);
    pub const white: Color = Color.argb(0xff, 0xff, 0xff, 0xff);
    pub const black: Color = Color.argb(0xff, 0x00, 0x00, 0x00);
    pub const surface_light: Color = Color.argb(0xd9, 0xff, 0xff, 0xff);
    pub const surface_dark: Color = Color.argb(0x40, 0x00, 0x00, 0x00);

    pub const slate1: Color = Color.argb(0xff, 0xfc, 0xfc, 0xfd);
    pub const slate2: Color = Color.argb(0xff, 0xf9, 0xf9, 0xfb);
    pub const slate3: Color = Color.argb(0xff, 0xf0, 0xf0, 0xf3);
    pub const slate7: Color = Color.argb(0xff, 0xcd, 0xce, 0xd6);
    pub const slate11: Color = Color.argb(0xff, 0x60, 0x64, 0x6c);
    pub const slate12: Color = Color.argb(0xff, 0x1c, 0x20, 0x24);
    pub const slate_a3: Color = Color.argb(0x0f, 0x00, 0x00, 0x33);
    pub const slate_a6: Color = Color.argb(0x26, 0x00, 0x00, 0x2f);
    pub const slate_a7: Color = Color.argb(0x32, 0x00, 0x06, 0x2e);
    pub const slate_a8: Color = Color.argb(0x46, 0x00, 0x08, 0x30);
    pub const slate_a10: Color = Color.argb(0x7f, 0x00, 0x07, 0x1b);
    pub const slate_a11: Color = Color.argb(0x9f, 0x00, 0x07, 0x14);

    pub const slate_dark1: Color = Color.argb(0xff, 0x11, 0x11, 0x13);
    pub const slate_dark2: Color = Color.argb(0xff, 0x18, 0x19, 0x1b);
    pub const slate_dark3: Color = Color.argb(0xff, 0x21, 0x22, 0x25);
    pub const slate_dark7: Color = Color.argb(0xff, 0x43, 0x48, 0x4e);
    pub const slate_dark11: Color = Color.argb(0xff, 0xb0, 0xb4, 0xba);
    pub const slate_dark12: Color = Color.argb(0xff, 0xed, 0xee, 0xf0);
    pub const slate_dark_a3: Color = Color.argb(0x14, 0xdd, 0xea, 0xf8);
    pub const slate_dark_a6: Color = Color.argb(0x30, 0xd6, 0xeb, 0xfd);
    pub const slate_dark_a7: Color = Color.argb(0x40, 0xd9, 0xed, 0xff);
    pub const slate_dark_a8: Color = Color.argb(0x5d, 0xd9, 0xed, 0xff);
    pub const slate_dark_a10: Color = Color.argb(0x7b, 0xe5, 0xed, 0xfd);
    pub const slate_dark_a11: Color = Color.argb(0xb5, 0xf1, 0xf7, 0xfe);

    pub const blue8: Color = Color.argb(0xff, 0x5e, 0xb1, 0xef);
    pub const blue9: Color = Color.argb(0xff, 0x00, 0x90, 0xff);
    pub const blue10: Color = Color.argb(0xff, 0x05, 0x88, 0xf0);
    pub const blue_a3: Color = Color.argb(0x19, 0x00, 0x8f, 0xf5);
    pub const blue_a4: Color = Color.argb(0x2a, 0x00, 0x9e, 0xff);
    pub const blue_a6: Color = Color.argb(0x53, 0x00, 0x88, 0xf6);
    pub const blue_a11: Color = Color.argb(0xf2, 0x00, 0x6d, 0xcb);
    pub const blue_dark8: Color = Color.argb(0xff, 0x28, 0x70, 0xbd);
    pub const blue_dark10: Color = Color.argb(0xff, 0x3b, 0x9e, 0xff);
    pub const blue_dark_a3: Color = Color.argb(0x3a, 0x00, 0x77, 0xff);
    pub const blue_dark_a4: Color = Color.argb(0x57, 0x00, 0x75, 0xff);
    pub const blue_dark_a6: Color = Color.argb(0x7f, 0x0f, 0x89, 0xfd);
    pub const blue_dark_a11: Color = Color.argb(0xff, 0x70, 0xb8, 0xff);
    pub const red9: Color = Color.argb(0xff, 0xe5, 0x48, 0x4d);

    pub const ink: Color = slate12;
    pub const panel: Color = slate2;
    pub const accent: Color = blue9;
};

/// Radix Themes design scales at 100% scaling and medium radius
/// (https://www.radix-ui.com/themes/docs/theme/spacing). Steps are 1-based
/// to match Radix token names: `space(3)` is Radix `--space-3`.
pub const scale = struct {
    pub const space_steps = [9]f32{ 4, 8, 12, 16, 24, 32, 40, 48, 64 };
    pub const font_size_steps = [9]f32{ 12, 14, 16, 18, 20, 24, 28, 35, 60 };
    pub const line_height_steps = [9]f32{ 16, 20, 24, 26, 28, 30, 36, 40, 60 };
    pub const radius_steps = [6]f32{ 3, 4, 6, 8, 12, 16 };

    pub fn space(step: usize) f32 {
        return space_steps[step - 1];
    }

    pub fn fontSize(step: usize) f32 {
        return font_size_steps[step - 1];
    }

    pub fn lineHeight(step: usize) f32 {
        return line_height_steps[step - 1];
    }

    pub fn radius(step: usize) f32 {
        return radius_steps[step - 1];
    }
};

pub const Brightness = enum {
    light,
    dark,
};

pub const ColorScheme = struct {
    brightness: Brightness,
    background: Color,
    foreground: Color,
    primary: Color,
    on_primary: Color,
    surface: Color,
    surface_high: Color,
    surface_low: Color,
    border: Color,
    muted: Color,
    error_color: Color,
    on_error: Color,

    pub const light: ColorScheme = .{
        .brightness = .light,
        .background = colors.white,
        .foreground = colors.ink,
        .primary = colors.accent,
        .on_primary = colors.white,
        .surface = colors.surface_light,
        .surface_high = colors.white,
        .surface_low = colors.slate2,
        .border = colors.slate_a7,
        .muted = colors.slate_a11,
        .error_color = colors.red9,
        .on_error = colors.white,
    };

    pub const dark: ColorScheme = .{
        .brightness = .dark,
        .background = colors.slate_dark1,
        .foreground = colors.slate_dark12,
        .primary = colors.blue9,
        .on_primary = colors.white,
        .surface = colors.surface_dark,
        .surface_high = colors.slate_dark2,
        .surface_low = colors.slate_dark2,
        .border = colors.slate_dark_a7,
        .muted = colors.slate_dark_a11,
        .error_color = colors.red9,
        .on_error = colors.white,
    };
};

pub const TextStyle = struct {
    color: ?Color = null,
    font_size: ?f32 = null,
    line_height: ?f32 = null,
};

pub const ResolvedTextStyle = struct {
    color: Color,
    font_size: f32,
    /// Null preserves the selected font face's natural line height.
    line_height: ?f32 = null,
};

pub const TextRole = enum {
    body,
    label,
    title,
};

pub const TextTheme = struct {
    body: TextStyle = .{ .font_size = scale.fontSize(3), .line_height = scale.lineHeight(3) },
    label: TextStyle = .{ .font_size = scale.fontSize(2), .line_height = scale.lineHeight(2) },
    title: TextStyle = .{ .font_size = scale.fontSize(5), .line_height = scale.lineHeight(5) },
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
    focused_border_width: f32 = 2,
    // Radix size-2 button: 20px label line plus 6px vertical padding,
    // space-3 horizontal padding, and radius-2.
    padding_x: f32 = scale.space(3),
    padding_y: f32 = (scale.space(6) - scale.lineHeight(2)) / 2,
    radius: f32 = scale.radius(2),
};

pub const InputTheme = struct {
    background: ?Color = null,
    foreground: ?Color = null,
    placeholder: ?Color = null,
    border: ?Color = null,
    focused_border: ?Color = null,
    // Radix size-2 text field: 32px tall, space-2 horizontal padding,
    // radius-2, font-size-2.
    padding_x: f32 = scale.space(2),
    padding_y: f32 = (scale.space(6) - scale.lineHeight(2)) / 2,
    radius: f32 = scale.radius(2),
    font_size: f32 = scale.fontSize(2),
    line_height: f32 = scale.lineHeight(2),
};

pub const SeparatorTheme = struct {
    color: ?Color = null,
};

pub const ScrollbarTheme = struct {
    track: ?Color = null,
    thumb: ?Color = null,
};

pub const Theme = struct {
    color_scheme: ColorScheme,
    text_theme: TextTheme = .{},
    button_theme: ButtonTheme = .{},
    input_theme: InputTheme = .{},
    separator_theme: SeparatorTheme = .{},
    scrollbar_theme: ScrollbarTheme = .{},

    pub const light: Theme = .{
        .color_scheme = .light,
        .button_theme = .{
            .background = colors.blue9,
            .foreground = colors.white,
            .hover_background = colors.blue10,
            .hover_foreground = colors.white,
            .focused_border = colors.blue8,
            .pressed_background = colors.blue10,
            .disabled_background = colors.slate_a3,
            .disabled_foreground = colors.slate_a8,
        },
        .input_theme = .{
            .background = colors.surface_light,
            .foreground = colors.slate12,
            .placeholder = colors.slate_a10,
            .border = colors.slate_a7,
            .focused_border = colors.blue8,
        },
        .separator_theme = .{ .color = colors.slate_a6 },
        .scrollbar_theme = .{ .track = colors.slate_a3, .thumb = colors.slate_a8 },
    };
    pub const dark: Theme = .{
        .color_scheme = .dark,
        .button_theme = .{
            .background = colors.blue9,
            .foreground = colors.white,
            .hover_background = colors.blue_dark10,
            .hover_foreground = colors.white,
            .focused_border = colors.blue_dark8,
            .pressed_background = colors.blue_dark10,
            .disabled_background = colors.slate_dark_a3,
            .disabled_foreground = colors.slate_dark_a8,
        },
        .input_theme = .{
            .background = colors.surface_dark,
            .foreground = colors.slate_dark12,
            .placeholder = colors.slate_dark_a10,
            .border = colors.slate_dark_a7,
            .focused_border = colors.blue_dark8,
        },
        .separator_theme = .{ .color = colors.slate_dark_a6 },
        .scrollbar_theme = .{ .track = colors.slate_dark_a3, .thumb = colors.slate_dark_a8 },
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

pub const PointerButton = enum {
    left,
    right,
    middle,
    back,
    forward,
};

pub const PointerButtons = struct {
    left: bool = true,
    right: bool = false,
    middle: bool = false,
    back: bool = false,
    forward: bool = false,

    pub fn accepts(self: PointerButtons, button: PointerButton) bool {
        return switch (button) {
            .left => self.left,
            .right => self.right,
            .middle => self.middle,
            .back => self.back,
            .forward => self.forward,
        };
    }

    pub const any: PointerButtons = .{ .left = true, .right = true, .middle = true, .back = true, .forward = true };
};

pub const Modifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
};

pub const TapSource = enum { pointer, keyboard };

pub const TapEvent = struct {
    source: TapSource,
    button: ?PointerButton = null,
    position: ?Point = null,
    local: ?Point = null,
    modifiers: Modifiers = .{},
};

pub const ShortcutKey = enum {
    enter,
    space,
    backspace,
    tab,
    escape,
    up,
    down,
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

pub const PointerButtonEvent = struct {
    button: PointerButton,
    state: PointerButtonState,
    position: Point,
    window_position: ?Point = null,
    modifiers: Modifiers = .{},
};

pub const ScrollEvent = struct {
    dx: f32,
    dy: f32,
    position: Point,
    window_position: ?Point = null,
    modifiers: Modifiers = .{},
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

    pub fn horizontal(self: EdgeInsets) f32 {
        return self.left + self.right;
    }

    pub fn vertical(self: EdgeInsets) f32 {
        return self.top + self.bottom;
    }
};

pub const Constraints = struct {
    max_width: f32,
    max_height: f32,
    min_width: f32 = 0,
    min_height: f32 = 0,

    pub fn inset(self: Constraints, padding: EdgeInsets) Constraints {
        return .{
            .max_width = @max(0, self.max_width - padding.horizontal()),
            .max_height = @max(0, self.max_height - padding.vertical()),
            .min_width = @max(0, self.min_width - padding.horizontal()),
            .min_height = @max(0, self.min_height - padding.vertical()),
        };
    }

    pub fn clamp(self: Constraints, size_value: Size) Size {
        // Max wins over min so a parent's hard bound is never exceeded.
        return .{
            .width = @min(@max(size_value.width, self.min_width), self.max_width),
            .height = @min(@max(size_value.height, self.min_height), self.max_height),
        };
    }

    /// Drops the min constraints. Containers that align their children
    /// absorb tightness themselves and lay children out loose.
    pub fn loosen(self: Constraints) Constraints {
        return .{ .max_width = self.max_width, .max_height = self.max_height };
    }
};

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
