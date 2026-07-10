//! Lua theme table decoding.

const std = @import("std");
const keywork = @import("../ui.zig");
const lua_codec = @import("codec.zig");
const lua_value = @import("value.zig");
const c = @import("luajit_c");

const pop = lua_value.pop;
const stringField = lua_value.stringField;

pub const TextOptions = struct {
    color: ?keywork.Color = null,
    size: ?f32 = null,
    font_size: ?f32 = null,
    role: ?keywork.TextRole = null,
    max_lines: ?u32 = null,
    overflow: ?keywork.Widget.TextOverflow = null,

    pub fn resolvedFontSize(self: TextOptions) ?f32 {
        return self.font_size orelse self.size;
    }
};

pub fn parseField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) keywork.Theme {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return .default;
    const theme_table = c.lua_gettop(lua_state);

    var theme = keywork.Theme.fromColorScheme(stringField(lua_state, theme_table, "color_scheme") catch "light");
    theme.color_scheme = parseColorScheme(lua_state, theme_table, theme.color_scheme);
    theme.text_theme = parseTextTheme(lua_state, theme_table, theme.text_theme);
    theme.button_theme = parseButtonTheme(lua_state, theme_table, theme.button_theme);
    theme.input_theme = parseInputTheme(lua_state, theme_table, theme.input_theme);
    return theme;
}

fn parseColorScheme(lua_state: *c.lua_State, theme_table: c_int, base: keywork.ColorScheme) keywork.ColorScheme {
    c.lua_getfield(lua_state, theme_table, "colors");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;
    const colors_table = c.lua_gettop(lua_state);
    return .{
        .brightness = base.brightness,
        .background = getColorField(lua_state, colors_table, "background", base.background),
        .foreground = getColorField(lua_state, colors_table, "foreground", base.foreground),
        .primary = getColorField(lua_state, colors_table, "primary", base.primary),
        .on_primary = getColorField(lua_state, colors_table, "on_primary", base.on_primary),
        .surface = getColorField(lua_state, colors_table, "surface", base.surface),
        .surface_high = getColorField(lua_state, colors_table, "surface_high", base.surface_high),
        .surface_low = getColorField(lua_state, colors_table, "surface_low", base.surface_low),
        .border = getColorField(lua_state, colors_table, "border", base.border),
        .muted = getColorField(lua_state, colors_table, "muted", base.muted),
        .error_color = getColorField(lua_state, colors_table, "error", base.error_color),
        .on_error = getColorField(lua_state, colors_table, "on_error", base.on_error),
    };
}

fn parseTextTheme(lua_state: *c.lua_State, theme_table: c_int, base: keywork.TextTheme) keywork.TextTheme {
    c.lua_getfield(lua_state, theme_table, "text");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;
    const text_table = c.lua_gettop(lua_state);
    var result = base;
    result.body = parseTextStyleField(lua_state, text_table, "body", result.body);
    result.label = parseTextStyleField(lua_state, text_table, "label", result.label);
    result.title = parseTextStyleField(lua_state, text_table, "title", result.title);
    return result;
}

fn parseTextStyleField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, base: keywork.TextStyle) keywork.TextStyle {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnil(lua_state, -1)) return base;
    if (c.lua_isnumber(lua_state, -1) != 0) {
        var result = base;
        result.color = colorFromStack(lua_state, -1) catch result.color;
        return result;
    }
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;

    const options = lua_codec.decode(TextOptions, lua_state, -1, std.heap.page_allocator) catch return base;
    return .{
        .color = options.color orelse base.color,
        .font_size = options.resolvedFontSize() orelse base.font_size,
    };
}

fn parseButtonTheme(lua_state: *c.lua_State, theme_table: c_int, base: keywork.ButtonTheme) keywork.ButtonTheme {
    c.lua_getfield(lua_state, theme_table, "components");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;
    const components_table = c.lua_gettop(lua_state);

    c.lua_getfield(lua_state, components_table, "button");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;
    const button_table = c.lua_gettop(lua_state);

    var result = base;
    result.padding_x = getNumberField(lua_state, button_table, "padding_x", result.padding_x);
    result.padding_y = getNumberField(lua_state, button_table, "padding_y", result.padding_y);
    result.radius = getNumberField(lua_state, button_table, "radius", result.radius);
    parseButtonStateTheme(lua_state, button_table, "default", &result.background, &result.foreground);
    parseButtonStateTheme(lua_state, button_table, "hover", &result.hover_background, &result.hover_foreground);
    parseButtonStateTheme(lua_state, button_table, "pressed", &result.pressed_background, null);
    parseButtonStateTheme(lua_state, button_table, "disabled", &result.disabled_background, &result.disabled_foreground);
    parseButtonFocusTheme(lua_state, button_table, &result.focused_border);
    return result;
}

fn parseButtonStateTheme(
    lua_state: *c.lua_State,
    button_table: c_int,
    key: [*:0]const u8,
    background: *?keywork.Color,
    foreground: ?*?keywork.Color,
) void {
    c.lua_getfield(lua_state, button_table, key);
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return;
    const state_table = c.lua_gettop(lua_state);
    background.* = getOptionalColorField(lua_state, state_table, "background") orelse background.*;
    if (foreground) |field| field.* = getOptionalColorField(lua_state, state_table, "foreground") orelse field.*;
}

fn parseButtonFocusTheme(lua_state: *c.lua_State, button_table: c_int, border: *?keywork.Color) void {
    c.lua_getfield(lua_state, button_table, "focused");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return;
    const focused_table = c.lua_gettop(lua_state);
    border.* = getOptionalColorField(lua_state, focused_table, "border") orelse border.*;
}

fn parseInputTheme(lua_state: *c.lua_State, theme_table: c_int, base: keywork.InputTheme) keywork.InputTheme {
    c.lua_getfield(lua_state, theme_table, "components");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;
    const components_table = c.lua_gettop(lua_state);

    c.lua_getfield(lua_state, components_table, "input");
    defer pop(lua_state, 1);
    if (c.lua_type(lua_state, -1) != c.LUA_TTABLE) return base;
    const input_table = c.lua_gettop(lua_state);

    var result = base;
    result.background = getOptionalColorField(lua_state, input_table, "background") orelse result.background;
    result.foreground = getOptionalColorField(lua_state, input_table, "foreground") orelse result.foreground;
    result.placeholder = getOptionalColorField(lua_state, input_table, "placeholder") orelse result.placeholder;
    result.border = getOptionalColorField(lua_state, input_table, "border") orelse result.border;
    result.focused_border = getOptionalColorField(lua_state, input_table, "focused_border") orelse result.focused_border;
    result.padding_x = getNumberField(lua_state, input_table, "padding_x", result.padding_x);
    result.padding_y = getNumberField(lua_state, input_table, "padding_y", result.padding_y);
    result.radius = getNumberField(lua_state, input_table, "radius", result.radius);
    result.font_size = getNumberField(lua_state, input_table, "font_size", result.font_size);
    return result;
}

fn getNumberField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, default: f32) f32 {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    if (c.lua_isnumber(lua_state, -1) == 0) return default;
    return @floatCast(c.lua_tonumber(lua_state, -1));
}

fn getColorField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8, default: keywork.Color) keywork.Color {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    return colorFromStack(lua_state, -1) catch default;
}

fn getOptionalColorField(lua_state: *c.lua_State, table: c_int, key: [*:0]const u8) ?keywork.Color {
    c.lua_getfield(lua_state, table, key);
    defer pop(lua_state, 1);
    return colorFromStack(lua_state, -1) catch null;
}

fn colorFromStack(lua_state: *c.lua_State, index: c_int) !keywork.Color {
    if (c.lua_isnumber(lua_state, index) == 0) return error.ExpectedLuaNumber;
    const value = c.lua_tonumber(lua_state, index);
    if (value < 0 or value > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return error.InvalidLuaColor;
    return @bitCast(@as(u32, @intFromFloat(value)));
}
