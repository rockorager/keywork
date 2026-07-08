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

    pub const slate_dark1: Color = Color.argb(0xff, 0x11, 0x11, 0x13);
    pub const slate_dark2: Color = Color.argb(0xff, 0x18, 0x19, 0x1b);
    pub const slate_dark3: Color = Color.argb(0xff, 0x21, 0x22, 0x25);
    pub const slate_dark7: Color = Color.argb(0xff, 0x43, 0x48, 0x4e);
    pub const slate_dark11: Color = Color.argb(0xff, 0xb0, 0xb4, 0xba);
    pub const slate_dark12: Color = Color.argb(0xff, 0xed, 0xee, 0xf0);

    pub const blue9: Color = Color.argb(0xff, 0x00, 0x90, 0xff);
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
        .background = colors.slate2,
        .foreground = colors.ink,
        .primary = colors.accent,
        .on_primary = colors.white,
        .surface = colors.slate1,
        .surface_high = colors.white,
        .surface_low = colors.slate3,
        .border = colors.slate7,
        .muted = colors.slate11,
        .error_color = colors.red9,
        .on_error = colors.white,
    };

    pub const dark: ColorScheme = .{
        .brightness = .dark,
        .background = colors.slate_dark1,
        .foreground = colors.slate_dark12,
        .primary = colors.blue9,
        .on_primary = colors.black,
        .surface = colors.slate_dark2,
        .surface_high = colors.slate_dark3,
        .surface_low = colors.slate_dark1,
        .border = colors.slate_dark7,
        .muted = colors.slate_dark11,
        .error_color = colors.red9,
        .on_error = colors.black,
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

pub const ShortcutKey = enum {
    enter,
    space,
    backspace,
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

    pub fn inset(self: Constraints, padding: EdgeInsets) Constraints {
        return .{
            .max_width = @max(0, self.max_width - padding.horizontal()),
            .max_height = @max(0, self.max_height - padding.vertical()),
        };
    }

    pub fn clamp(self: Constraints, size_value: Size) Size {
        return .{
            .width = @min(size_value.width, self.max_width),
            .height = @min(size_value.height, self.max_height),
        };
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
