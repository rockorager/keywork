local ui = {}

-- Radix Themes scales at 100% scaling and medium radius, mirroring `scale`
-- in src/ui/types.zig. Lua's 1-based arrays match Radix token names:
-- space_scale[3] is Radix --space-3.
local space_scale = { 4, 8, 12, 16, 24, 32, 40, 48, 64 }
local font_size_scale = { 12, 14, 16, 18, 20, 24, 28, 35, 60 }
local line_height_scale = { 16, 20, 24, 26, 28, 30, 36, 40, 60 }
local radius_scale = { 3, 4, 6, 8, 12, 16 }
local control_padding_y = (space_scale[6] - line_height_scale[2]) / 2
local badge_gap = space_scale[1] * 1.5

local default_theme = {
  schemes = {
    light = {
      colors = {
        black = 0xff000000,
        white = 0xffffffff,
        black_a1 = 0x0d000000,
        black_a2 = 0x1a000000,
        black_a3 = 0x26000000,
        black_a4 = 0x33000000,
        black_a5 = 0x4d000000,
        black_a6 = 0x59000000,
        black_a7 = 0x70000000,
        black_a11 = 0xb8000000,

        slate1 = 0xfffcfcfd,
        slate2 = 0xfff9f9fb,
        slate3 = 0xfff0f0f3,
        slate4 = 0xffe8e8ec,
        slate5 = 0xffe0e1e6,
        slate6 = 0xffd9d9e0,
        slate7 = 0xffcdced6,
        slate8 = 0xffb9bbc6,
        slate9 = 0xff8b8d98,
        slate10 = 0xff80838d,
        slate11 = 0xff60646c,
        slate12 = 0xff1c2024,
        slate_a1 = 0x03000055,
        slate_a2 = 0x06000055,
        slate_a3 = 0x0f000033,
        slate_a4 = 0x1700002d,
        slate_a5 = 0x1f000038,
        slate_a6 = 0x2600002f,
        slate_a7 = 0x3200062e,
        slate_a8 = 0x46000830,
        slate_a9 = 0x7400051d,
        slate_a10 = 0x7f00071b,
        slate_a11 = 0x9f000714,

        blue1 = 0xfffbfdff,
        blue2 = 0xfff4faff,
        blue3 = 0xffe6f4fe,
        blue4 = 0xffd5efff,
        blue5 = 0xffc2e5ff,
        blue6 = 0xffacd8fc,
        blue7 = 0xff8ec8f6,
        blue8 = 0xff5eb1ef,
        blue9 = 0xff0090ff,
        blue10 = 0xff0588f0,
        blue11 = 0xff0d74ce,
        blue12 = 0xff113264,
        blue_a3 = 0x19008ff5,
        blue_a4 = 0x2a009eff,
        blue_a5 = 0x3d0093ff,
        blue_a6 = 0x530088f6,
        blue_a11 = 0xf2006dcb,

        red = 0xffe5484d,
        orange = 0xfff76b15,
        yellow = 0xffffe629,
        green = 0xff30a46c,
        mint = 0xff86ead4,
        teal = 0xff12a594,
        cyan = 0xff00a2c7,
        blue = "blue9",
        indigo = 0xff3e63dd,
        purple = 0xff8e4ec6,
        pink = 0xffd6409f,
        brown = 0xffad7f58,
        gray = "slate9",
        gray2 = "slate8",
        gray3 = "slate7",
        gray4 = "slate6",
        gray5 = "slate4",
        gray6 = "slate3",

        label = "slate12",
        secondary_label = "slate11",
        tertiary_label = "slate10",
        quaternary_label = "slate9",
        system_background = "white",
        secondary_system_background = "slate2",
        tertiary_system_background = "white",
        system_fill = "slate4",
        secondary_system_fill = "slate3",
        tertiary_system_fill = "slate2",
        quaternary_system_fill = "slate1",
        separator = "slate6",
        opaque_separator = "slate6",
        panel_border = "slate3",

        background = "system_background",
        surface = "secondary_system_background",
        surface_high = "tertiary_system_background",
        surface_low = "slate2",
        text = "label",
        text_secondary = "secondary_label",
        text_tertiary = "tertiary_label",
        placeholder = "slate10",
        border = "slate7",
        fill = "system_fill",
        fill_secondary = "secondary_system_fill",

        accent3 = "blue3",
        accent4 = "blue4",
        accent5 = "blue5",
        accent6 = "blue6",
        accent8 = "blue8",
        accent9 = "blue9",
        accent10 = "blue10",
        accent11 = "blue11",
        accent_a3 = "blue_a3",
        accent_a4 = "blue_a4",
        accent_a5 = "blue_a5",
        accent_a6 = "blue_a6",
        accent_a11 = "blue_a11",
        accent = "accent9",
        focus8 = "accent8",
        on_accent = "white",
        success = "green",
        on_success = "white",
        warning = "yellow",
        on_warning = "black",
        danger = "red",
        on_danger = "white",
        info = "cyan",
        on_info = "white",

        foreground = "text",
        muted = "text_secondary",
        primary = "accent",
        on_primary = "on_accent",
        error = "danger",
        on_error = "on_danger",
      },
      -- Public Radix outer shadow layers. Shadow-1 is inset-only and remains
      -- unavailable until Keywork supports inner shadows.
      shadow = {
        [2] = {
          { spread = 1, color = "slate_a3" },
          { spread = 0.5, color = "black_a1" },
          { offset_y = 1, blur = 1, color = "slate_a2" },
          { offset_y = 2, blur = 1, spread = -1, color = "black_a1" },
          { offset_y = 1, blur = 3, color = "black_a1" },
        },
        [3] = {
          { spread = 1, color = "slate_a3" },
          { offset_y = 2, blur = 3, spread = -2, color = "slate_a3" },
          { offset_y = 3, blur = 12, spread = -4, color = "black_a2" },
          { offset_y = 4, blur = 16, spread = -8, color = "black_a2" },
        },
        [4] = {
          { spread = 1, color = "slate_a3" },
          { offset_y = 8, blur = 40, color = "black_a1" },
          { offset_y = 12, blur = 32, spread = -16, color = "slate_a3" },
        },
        [5] = {
          { spread = 1, color = "slate_a3" },
          { offset_y = 12, blur = 60, color = "black_a3" },
          { offset_y = 12, blur = 32, spread = -16, color = "slate_a5" },
        },
        [6] = {
          { spread = 1, color = "slate_a3" },
          { offset_y = 12, blur = 60, color = "black_a3" },
          { offset_y = 16, blur = 64, color = "slate_a2" },
          { offset_y = 16, blur = 36, spread = -20, color = "slate_a7" },
        },
      },
    },
    dark = {
      colors = {
        black = 0xff000000,
        white = 0xffffffff,
        black_a1 = 0x0d000000,
        black_a2 = 0x1a000000,
        black_a3 = 0x26000000,
        black_a4 = 0x33000000,
        black_a5 = 0x4d000000,
        black_a6 = 0x59000000,
        black_a7 = 0x70000000,
        black_a11 = 0xb8000000,

        slate1 = 0xff111113,
        slate2 = 0xff18191b,
        slate3 = 0xff212225,
        slate4 = 0xff272a2d,
        slate5 = 0xff2e3135,
        slate6 = 0xff363a3f,
        slate7 = 0xff43484e,
        slate8 = 0xff5a6169,
        slate9 = 0xff696e77,
        slate10 = 0xff777b84,
        slate11 = 0xffb0b4ba,
        slate12 = 0xffedeef0,
        slate_a2 = 0x09d8f4f6,
        slate_a3 = 0x14ddeaf8,
        slate_a4 = 0x1dd3edf8,
        slate_a5 = 0x25d9edff,
        slate_a6 = 0x30d6ebfd,
        slate_a7 = 0x40d9edff,
        slate_a8 = 0x5dd9edff,
        slate_a9 = 0x6ddfebfd,
        slate_a10 = 0x7be5edfd,
        slate_a11 = 0xb5f1f7fe,

        blue1 = 0xff0d1520,
        blue2 = 0xff111927,
        blue3 = 0xff0d2847,
        blue4 = 0xff003362,
        blue5 = 0xff004074,
        blue6 = 0xff104d87,
        blue7 = 0xff205d9e,
        blue8 = 0xff2870bd,
        blue9 = 0xff0090ff,
        blue10 = 0xff3b9eff,
        blue11 = 0xff70b8ff,
        blue12 = 0xffc2e6ff,
        blue_a3 = 0x3a0077ff,
        blue_a4 = 0x570075ff,
        blue_a5 = 0x6b0081fd,
        blue_a6 = 0x7f0f89fd,
        blue_a11 = 0xff70b8ff,

        red = 0xffe5484d,
        orange = 0xfff76b15,
        yellow = 0xffffe629,
        green = 0xff30a46c,
        mint = 0xff86ead4,
        teal = 0xff12a594,
        cyan = 0xff00a2c7,
        blue = "blue9",
        indigo = 0xff3e63dd,
        purple = 0xff8e4ec6,
        pink = 0xffd6409f,
        brown = 0xffad7f58,
        gray = "slate9",
        gray2 = "slate8",
        gray3 = "slate7",
        gray4 = "slate6",
        gray5 = "slate5",
        gray6 = "slate3",

        label = "slate12",
        secondary_label = "slate11",
        tertiary_label = "slate10",
        quaternary_label = "slate9",
        system_background = "slate1",
        secondary_system_background = "slate2",
        tertiary_system_background = "slate2",
        system_fill = "slate4",
        secondary_system_fill = "slate3",
        tertiary_system_fill = "slate2",
        quaternary_system_fill = "slate1",
        separator = "slate6",
        opaque_separator = "slate6",
        panel_border = "slate6",

        background = "system_background",
        surface = "secondary_system_background",
        surface_high = "tertiary_system_background",
        surface_low = "slate2",
        text = "label",
        text_secondary = "secondary_label",
        text_tertiary = "tertiary_label",
        placeholder = "slate10",
        border = "slate7",
        fill = "system_fill",
        fill_secondary = "secondary_system_fill",

        accent3 = "blue3",
        accent4 = "blue4",
        accent5 = "blue5",
        accent6 = "blue6",
        accent8 = "blue8",
        accent9 = "blue9",
        accent10 = "blue10",
        accent11 = "blue11",
        accent_a3 = "blue_a3",
        accent_a4 = "blue_a4",
        accent_a5 = "blue_a5",
        accent_a6 = "blue_a6",
        accent_a11 = "blue_a11",
        accent = "accent9",
        focus8 = "accent8",
        on_accent = "white",
        success = "green",
        on_success = "white",
        warning = "yellow",
        on_warning = "black",
        danger = "red",
        on_danger = "white",
        info = "cyan",
        on_info = "white",

        foreground = "text",
        muted = "text_secondary",
        primary = "accent",
        on_primary = "on_accent",
        error = "danger",
        on_error = "on_danger",
      },
      shadow = {
        [2] = {
          { spread = 1, color = "slate_a6" },
          { spread = 0.5, color = "black_a3" },
          { offset_y = 1, blur = 1, color = "black_a6" },
          { offset_y = 2, blur = 1, spread = -1, color = "black_a6" },
          { offset_y = 1, blur = 3, color = "black_a5" },
        },
        [3] = {
          { spread = 1, color = "slate_a6" },
          { offset_y = 2, blur = 3, spread = -2, color = "black_a3" },
          { offset_y = 3, blur = 8, spread = -2, color = "black_a6" },
          { offset_y = 4, blur = 12, spread = -4, color = "black_a7" },
        },
        [4] = {
          { spread = 1, color = "slate_a6" },
          { offset_y = 8, blur = 40, color = "black_a3" },
          { offset_y = 12, blur = 32, spread = -16, color = "black_a5" },
        },
        [5] = {
          { spread = 1, color = "slate_a6" },
          { offset_y = 12, blur = 60, color = "black_a5" },
          { offset_y = 12, blur = 32, spread = -16, color = "black_a7" },
        },
        [6] = {
          { spread = 1, color = "slate_a6" },
          { offset_y = 12, blur = 60, color = "black_a4" },
          { offset_y = 16, blur = 64, color = "black_a6" },
          { offset_y = 16, blur = 36, spread = -20, color = "black_a11" },
        },
      },
    },
  },

  text = {
    body = { size = font_size_scale[3], line_height = line_height_scale[3] },
    label = { size = font_size_scale[2], line_height = line_height_scale[2] },
    title = { size = font_size_scale[5], line_height = line_height_scale[5] },
  },

  space = space_scale,
  font_size = font_size_scale,
  line_height = line_height_scale,
  radius = radius_scale,

  components = {
    button = {
      -- Radix size-2 button: 20px label line plus 6px vertical padding,
      -- space-3 horizontal padding, and radius-2.
      padding_x = space_scale[3],
      padding_y = control_padding_y,
      radius = radius_scale[2],
      default = {
        background = "accent",
        foreground = "on_accent",
      },
      hover = {
        background = "accent10",
        foreground = "on_accent",
      },
      pressed = {
        background = "accent10",
        foreground = "on_accent",
      },
      disabled = {
        background = "slate3",
        foreground = "slate8",
      },
      focused = {
        border = "focus8",
        border_width = 2,
      },
    },

    input = {
      -- Radix size-2 text field: 32px tall, space-2 horizontal padding,
      -- radius-2, font-size-2.
      padding_x = space_scale[2],
      padding_y = control_padding_y,
      radius = radius_scale[2],
      font_size = font_size_scale[2],
      line_height = line_height_scale[2],
      background = "surface",
      foreground = "text",
      placeholder = "slate10",
      border = "slate7",
      focused_border = "focus8",
    },

    chip = {
      -- Radix size-2 Badge geometry and soft colors.
      padding_x = space_scale[2],
      padding_y = space_scale[1],
      radius = radius_scale[2],
      min_height = space_scale[5],
      font_size = font_size_scale[1],
      line_height = line_height_scale[1],
      icon_size = space_scale[3],
      gap = badge_gap,
      background = "accent3",
      foreground = "accent11",
      hover_background = "accent4",
      pressed_background = "accent5",
      focused_border = "focus8",
      focused_border_width = 2,
      selected_background = "accent9",
      selected_foreground = "on_accent",
      selected_hover_background = "accent10",
      selected_pressed_background = "accent10",
    },

    menu = {
      -- Radix size-2 menu content and the soft highlighted-item variant.
      background = "surface_high",
      border = "panel_border",
      border_width = 1,
      radius = radius_scale[4],
      padding = space_scale[2],
      item = {
        padding_x = space_scale[3],
        padding_y = control_padding_y,
        min_height = space_scale[6],
        radius = radius_scale[2],
        font_size = font_size_scale[2],
        line_height = line_height_scale[2],
        hover_background = "accent4",
        selected_background = "accent4",
        selected_hover_background = "accent4",
      },
      label = {
        padding_x = space_scale[3],
        padding_y = control_padding_y,
        min_height = space_scale[6],
        font_size = font_size_scale[2],
        line_height = line_height_scale[2],
        foreground = "slate10",
      },
      separator = {
        color = "slate6",
        thickness = 1,
        margin = space_scale[2],
        inset = space_scale[1],
      },
    },

    separator = {
      color = "slate6",
      thickness = 1,
    },

    scrollbar = {
      track = "slate3",
      thumb = "slate8",
    },
  },
}

local function copy_table(value)
  local result = {}
  for key, child in pairs(value or {}) do
    if type(child) == "table" then
      result[key] = copy_table(child)
    else
      result[key] = child
    end
  end
  return result
end

local function merge_table(base, overrides)
  local result = copy_table(base)
  for key, value in pairs(overrides or {}) do
    if type(value) == "table" and type(result[key]) == "table" then
      result[key] = merge_table(result[key], value)
    else
      result[key] = value
    end
  end
  return result
end

function ui.theme_data(options)
  options = options or {}
  local result = merge_table(default_theme, options)
  -- A custom font size without a matching line height keeps the historical
  -- font-metrics fallback instead of inheriting an unrelated Radix pair.
  for role, style in pairs(options.text or {}) do
    if type(style) == "table" and (style.size ~= nil or style.font_size ~= nil) and style.line_height == nil then
      result.text[role].line_height = nil
    end
  end
  return result
end

local function resolve_ref(value, tokens)
  if type(value) == "string" then
    return tokens[value]
  end
  return value
end

local function resolve_token(name, tokens, resolved, resolving)
  if resolved[name] ~= nil then
    return resolved[name]
  end

  if resolving[name] then
    error("cyclic color alias: " .. name)
  end

  local value = tokens[name]
  if type(value) == "string" then
    if tokens[value] == nil then
      error("unknown color alias: " .. name .. " -> " .. value)
    end
    resolving[name] = true
    value = resolve_token(value, tokens, resolved, resolving)
    resolving[name] = nil
  end

  resolved[name] = value
  return value
end

local function resolve_colors(colors)
  local resolved = {}
  for name in pairs(colors or {}) do
    resolve_token(name, colors, resolved, {})
  end
  return resolved
end

local function resolve_color(value, colors)
  return resolve_ref(value, colors)
end

local function resolve_space(value, space)
  return resolve_ref(value, space)
end

local function resolve_radius(value, radius)
  return resolve_ref(value, radius)
end

local function resolve_shadows(shadows, colors)
  local result = {}
  for level, layers in pairs(shadows or {}) do
    result[level] = {}
    for index, layer in ipairs(layers) do
      result[level][index] = {
        color = resolve_color(layer.color, colors),
        offset_x = layer.offset_x or 0,
        offset_y = layer.offset_y or 0,
        blur = layer.blur or 0,
        spread = layer.spread or 0,
      }
    end
  end
  return result
end

local function resolve_button(button, colors, space, radius)
  button = button or {}
  return {
    padding_x = resolve_space(button.padding_x, space),
    padding_y = resolve_space(button.padding_y, space),
    radius = resolve_radius(button.radius, radius),
    default = {
      background = resolve_color(button.default and button.default.background, colors),
      foreground = resolve_color(button.default and button.default.foreground, colors),
    },
    hover = {
      background = resolve_color(button.hover and button.hover.background, colors),
      foreground = resolve_color(button.hover and button.hover.foreground, colors),
    },
    pressed = {
      background = resolve_color(button.pressed and button.pressed.background, colors),
      foreground = resolve_color(button.pressed and button.pressed.foreground, colors),
    },
    disabled = {
      background = resolve_color(button.disabled and button.disabled.background, colors),
      foreground = resolve_color(button.disabled and button.disabled.foreground, colors),
    },
    focused = {
      border = resolve_color(button.focused and button.focused.border, colors),
      border_width = button.focused and button.focused.border_width,
    },
  }
end

local function resolve_input(input, colors, space, radius)
  input = input or {}
  return {
    padding_x = resolve_space(input.padding_x, space),
    padding_y = resolve_space(input.padding_y, space),
    radius = resolve_radius(input.radius, radius),
    font_size = input.font_size,
    line_height = input.line_height,
    background = resolve_color(input.background, colors),
    foreground = resolve_color(input.foreground, colors),
    placeholder = resolve_color(input.placeholder, colors),
    border = resolve_color(input.border, colors),
    focused_border = resolve_color(input.focused_border, colors),
  }
end

local function resolve_chip(chip, colors, space, radius)
  chip = chip or {}
  return {
    padding_x = resolve_space(chip.padding_x, space),
    padding_y = resolve_space(chip.padding_y, space),
    radius = resolve_radius(chip.radius, radius),
    min_height = resolve_space(chip.min_height, space),
    font_size = chip.font_size,
    line_height = chip.line_height,
    icon_size = resolve_space(chip.icon_size, space),
    gap = resolve_space(chip.gap, space),
    background = resolve_color(chip.background, colors),
    foreground = resolve_color(chip.foreground, colors),
    hover_background = resolve_color(chip.hover_background, colors),
    pressed_background = resolve_color(chip.pressed_background, colors),
    focused_border = resolve_color(chip.focused_border, colors),
    focused_border_width = chip.focused_border_width,
    selected_background = resolve_color(chip.selected_background, colors),
    selected_foreground = resolve_color(chip.selected_foreground, colors),
    selected_hover_background = resolve_color(chip.selected_hover_background, colors),
    selected_pressed_background = resolve_color(chip.selected_pressed_background, colors),
  }
end

local function resolve_menu(menu, colors, space, radius, shadow)
  menu = menu or {}
  local item = menu.item or {}
  local label = menu.label or {}
  local separator = menu.separator or {}
  return {
    background = resolve_color(menu.background, colors),
    border = resolve_color(menu.border, colors),
    border_width = menu.border_width,
    radius = resolve_radius(menu.radius, radius),
    padding = resolve_space(menu.padding, space),
    shadow = type(menu.shadow) == "number" and shadow[menu.shadow] or menu.shadow,
    item = {
      padding_x = resolve_space(item.padding_x, space),
      padding_y = resolve_space(item.padding_y, space),
      min_height = resolve_space(item.min_height, space),
      radius = resolve_radius(item.radius, radius),
      font_size = item.font_size,
      line_height = item.line_height,
      hover_background = resolve_color(item.hover_background, colors),
      selected_background = resolve_color(item.selected_background, colors),
      selected_hover_background = resolve_color(item.selected_hover_background, colors),
    },
    label = {
      padding_x = resolve_space(label.padding_x, space),
      padding_y = resolve_space(label.padding_y, space),
      min_height = resolve_space(label.min_height, space),
      font_size = label.font_size,
      line_height = label.line_height,
      foreground = resolve_color(label.foreground, colors),
    },
    separator = {
      color = resolve_color(separator.color, colors),
      thickness = separator.thickness,
      margin = resolve_space(separator.margin, space),
      inset = resolve_space(separator.inset, space),
    },
  }
end

local function resolve_separator(separator, colors)
  separator = separator or {}
  return {
    color = resolve_color(separator.color, colors),
    thickness = separator.thickness,
  }
end

local function resolve_scrollbar(scrollbar, colors)
  scrollbar = scrollbar or {}
  return {
    track = resolve_color(scrollbar.track, colors),
    thumb = resolve_color(scrollbar.thumb, colors),
  }
end

function ui.resolve_theme(theme, state_or_scheme)
  theme = theme or default_theme
  local color_scheme = "light"
  if type(state_or_scheme) == "table" then
    color_scheme = state_or_scheme.color_scheme or color_scheme
  elseif type(state_or_scheme) == "string" then
    color_scheme = state_or_scheme
  end
  if color_scheme == "no-preference" then
    color_scheme = "light"
  end

  local scheme = theme.schemes[color_scheme] or theme.schemes.light
  local colors = resolve_colors(scheme.colors)
  local space = copy_table(theme.space or {})
  local font_size = copy_table(theme.font_size or {})
  local line_height = copy_table(theme.line_height or {})
  local radius = copy_table(theme.radius or {})
  local shadow = resolve_shadows(scheme.shadow or theme.shadow, colors)
  local components = {
    button = resolve_button(theme.components and theme.components.button, colors, space, radius),
    input = resolve_input(theme.components and theme.components.input, colors, space, radius),
    chip = resolve_chip(theme.components and theme.components.chip, colors, space, radius),
    menu = resolve_menu(theme.components and theme.components.menu, colors, space, radius, shadow),
    separator = resolve_separator(theme.components and theme.components.separator, colors),
    scrollbar = resolve_scrollbar(theme.components and theme.components.scrollbar, colors),
  }

  return {
    color_scheme = color_scheme,
    colors = colors,
    text = copy_table(theme.text or {}),
    space = space,
    font_size = font_size,
    line_height = line_height,
    radius = radius,
    shadow = shadow,
    components = components,
  }
end

function ui.theme_for(state, theme)
  return ui.resolve_theme(theme or default_theme, state)
end

function ui.text(value, style)
  style = style or {}
  return {
    type = "text",
    value = value,
    color = style.color,
    size = style.size,
    font_size = style.font_size,
    line_height = style.line_height,
    role = style.role,
    max_lines = style.max_lines,
    overflow = style.overflow,
    line_break = style.line_break,
  }
end

function ui.label(value, options)
  options = options or {}
  return ui.text(value, { color = options.color, size = options.size, font_size = options.font_size, line_height = options.line_height, role = options.role or "label", max_lines = options.max_lines, overflow = options.overflow, line_break = options.line_break })
end

function ui.keyed(key, child)
  return {
    type = "keyed",
    key = key,
    child = child,
  }
end

function ui.stateful(spec)
  local build = spec.build
  if build then
    spec = setmetatable({
      build = function(self, context)
        context = context or {}
        context.theme = context.theme or ui.theme_for(context)
        return build(self, context)
      end,
    }, { __index = spec })
  end

  return function(props)
    props = props or {}
    local widget = {
      type = "stateful",
      spec = spec,
      props = props,
    }
    if props.key then
      return ui.keyed(props.key, widget)
    end
    return widget
  end
end

function ui.theme(options)
  options = options or {}
  return {
    type = "theme",
    theme = options.data or options.theme,
    child = options.child,
  }
end

function ui.default_text_style(options)
  options = options or {}
  return {
    type = "default_text_style",
    color = options.color,
    size = options.size,
    font_size = options.font_size,
    line_height = options.line_height,
    child = options.child,
  }
end

function ui.icon_theme(options)
  options = options or {}
  return {
    type = "icon_theme",
    color = options.color,
    size = options.size,
    symbolic = options.symbolic,
    child = options.child,
  }
end

function ui.box(style, child)
  style = style or {}
  return {
    type = "box",
    background = style.background,
    border = style.border,
    border_width = style.border_width,
    radius = style.radius,
    shadow = style.shadow,
    min_width = style.min_width,
    min_height = style.min_height,
    align = style.align,
    horizontal_align = style.horizontal_align,
    vertical_align = style.vertical_align,
    child = child,
  }
end

function ui.container(options, child)
  options = options or {}
  if options.child then
    child = options.child
  end
  if options.padding then
    local padding = options.padding
    if type(padding) == "number" then
      child = ui.padding({ all = padding, child = child })
    else
      child = ui.padding({
        all = padding.all,
        x = padding.x,
        y = padding.y,
        left = padding.left,
        right = padding.right,
        top = padding.top,
        bottom = padding.bottom,
        child = child,
      })
    end
  end
  return ui.box({
    background = options.background,
    border = options.border,
    border_width = options.border_width,
    radius = options.radius,
    shadow = options.shadow,
    min_width = options.min_width,
    min_height = options.min_height,
    align = options.align,
    horizontal_align = options.horizontal_align,
    vertical_align = options.vertical_align,
  }, child)
end

function ui.gesture(options)
  return {
    type = "gesture",
    id = options.id,
    child = options.child,
    hover_background = options.hover_background,
    pressed_background = options.pressed_background,
    focused_border = options.focused_border,
    focused_border_width = options.focused_border_width,
    cursor = options.cursor,
    activation = options.activation,
    on_tap = options.on_tap,
    on_tap_down = options.on_tap_down,
    on_tap_up = options.on_tap_up,
    on_tap_cancel = options.on_tap_cancel,
    on_hover = options.on_hover,
    buttons = options.buttons,
    on_scroll = options.on_scroll,
  }
end

--- Composable press primitive: hover/pressed backgrounds, a focused
--- border, cursor shape, and tap callbacks around any child. The child
--- should be a box/container so state backgrounds and borders have
--- somewhere to paint. A pressable with `on_tap` participates in focus
--- traversal, so Enter/Space activate it and `focused_border` marks
--- keyboard focus. Hover and press restyle in place without rebuilding
--- the app. `on_hover(hovered)` fires on pointer enter/leave, driven only
--- by real pointer motion (content scrolling beneath a stationary
--- pointer does not re-fire it).
---
--- `on_tap` fires on pointer-down by default (the desktop feels
--- snappier). Pass `activation = "release"` to wait for pointer-up over
--- the same target, letting a press be aborted by dragging off before
--- letting go.
function ui.pressable(options)
  return {
    type = "gesture",
    id = options.id,
    child = options.child,
    hover_background = options.hover_background,
    pressed_background = options.pressed_background,
    focused_border = options.focused_border,
    focused_border_width = options.focused_border_width,
    cursor = options.cursor,
    activation = options.activation,
    on_tap = options.on_tap,
    on_tap_down = options.on_tap_down,
    on_tap_up = options.on_tap_up,
    on_tap_cancel = options.on_tap_cancel,
    on_hover = options.on_hover,
    buttons = options.buttons,
    on_scroll = options.on_scroll,
  }
end

--- Declares that a popup may hang off this widget's laid-out rect. The
--- child renders inline; when `popup` is set (see ui.popup) the runtime
--- realizes it as a separate surface anchored to this widget. Popup
--- existence is state-driven: builds that omit `popup` dismiss it.
function ui.anchored(options)
  return {
    type = "anchored",
    id = options.id,
    child = options.child,
    popup = options.popup,
  }
end

--- Declares one window of the app's window set, returned from the app's
--- `windows(ctx)` function. Windows are diffed by `id`: a newly declared
--- id creates a surface, a dropped id destroys it. Fields left nil
--- inherit the app-level defaults; `output` names the output a
--- layer-shell window is placed on (see ctx.outputs). A layer-shell window's
--- height may be `"content"`; its retained root child is then laid out under
--- a loose, output-capped height. Prefer natural or loose Flexible children
--- over Expanded in a shrink-wrapped direction.
---
--- A callable table rather than a function: the runtime attaches
--- window-level operations (start_move, start_resize,
--- request_activation_token) to it.
ui.window = setmetatable({}, {
  __call = function(_, options)
    return {
      id = options.id,
      title = options.title,
      width = options.width,
      height = options.height,
      output = options.output,
      layer_shell = options.layer_shell,
      child = options.child,
    }
  end,
})

--- Popup declaration for ui.anchored. `content` is a widget table, or a
--- function receiving the popup's runtime state and returning one.
--- `on_close` fires when Escape is pressed or the compositor dismisses the
--- popup (for example a click elsewhere), so app state can stop declaring it.
function ui.popup(options)
  return {
    content = options.content,
    edge = options.edge,
    alignment = options.alignment,
    gap = options.gap,
    width = options.width,
    height = options.height,
    on_close = options.on_close,
  }
end

function ui.focus(options)
  options = options or {}
  return {
    type = "focus",
    id = options.id,
    child = options.child,
    autofocus = options.autofocus or false,
    skip_traversal = options.skip_traversal or false,
    can_request_focus = options.can_request_focus ~= false,
    on_focus_change = options.on_focus_change,
  }
end

function ui.focus_scope(options)
  options = options or {}
  return {
    type = "focus_scope",
    id = options.id,
    child = options.child,
    modal = options.modal or false,
  }
end

function ui.text_input(options)
  options = options or {}
  return {
    type = "text_input",
    id = options.id,
    placeholder = options.placeholder,
    value = options.value,
    on_change = options.on_change,
    on_submit = options.on_submit,
    obscured = options.obscured or false,
    clear_on_submit = options.clear_on_submit or false,
    autofocus = options.autofocus or false,
    variant = options.variant,
    background = options.background,
    foreground = options.foreground,
    placeholder_color = options.placeholder_color,
    border = options.border,
    focused_border = options.focused_border,
    padding_x = options.padding_x,
    padding_y = options.padding_y,
    radius = options.radius,
    font_size = options.font_size,
    line_height = options.line_height,
  }
end

function ui.scroll(options)
  options = options or {}
  return {
    type = "scroll",
    id = options.id,
    child = options.child,
    axes = options.axes,
  }
end

function ui.list(options)
  options = options or {}
  return {
    type = "list",
    id = options.id,
    count = options.count,
    item_height = options.item_height,
    selected = options.selected,
    build_item = options.build_item,
  }
end

function ui.column(options)
  options = options or {}
  return {
    type = "column",
    children = options.children,
    spacing = options.spacing or 0,
    align = options.align,
    main_align = options.main_align,
  }
end

function ui.row(options)
  options = options or {}
  return {
    type = "row",
    children = options.children,
    spacing = options.spacing or 0,
    align = options.align,
    main_align = options.main_align,
  }
end

function ui.expanded(child, flex)
  return {
    type = "flexible",
    child = child,
    flex = flex or 1,
    fit = "tight",
  }
end

function ui.flexible(child, flex)
  return {
    type = "flexible",
    child = child,
    flex = flex or 1,
    fit = "loose",
  }
end

function ui.sized(options, child)
  options = options or {}
  if options.child then
    child = options.child
  end
  return {
    type = "sized",
    child = child,
    width = options.width,
    height = options.height,
    min_width = options.min_width,
    min_height = options.min_height,
    max_width = options.max_width,
    max_height = options.max_height,
  }
end

function ui.separator(options)
  options = options or {}
  return {
    type = "separator",
    color = options.color,
    thickness = options.thickness,
    axis = options.axis,
    margin = options.margin,
  }
end

function ui.spacer(flex)
  return {
    type = "spacer",
    flex = flex or 1,
  }
end

function ui.spinner(options)
  options = options or {}
  return {
    type = "spinner",
    size = options.size,
    color = options.color,
    period_ms = options.period_ms,
  }
end

function ui.svg_icon(options)
  options = options or {}
  return {
    type = "svg_icon",
    path = options.path,
    size = options.size,
    color = options.color,
  }
end

function ui.image(options)
  options = options or {}
  return {
    type = "image",
    path = options.path,
    width = options.width,
    height = options.height,
    size = options.size,
    format = options.format,
    pixels = options.pixels,
    fit = options.fit,
    align = options.align,
    cache = options.cache,
    revision = options.revision,
  }
end

function ui.icon(options)
  options = options or {}
  return {
    type = "icon",
    name = options.name,
    size = options.size,
    color = options.color,
    symbolic = options.symbolic,
  }
end

function ui.icon_label(icon_name, text, options)
  options = options or {}
  -- No size default here: a nil size falls through to the enclosing
  -- icon_theme context or the bridge's Radix space-4 default.
  local children = { ui.icon({
    name = icon_name,
    size = options.size,
    color = options.color,
    symbolic = options.symbolic,
  }) }
  if text and text ~= "" then
    table.insert(children, ui.label(text, { color = options.color, size = options.label_size, font_size = options.font_size, line_height = options.line_height, role = options.role }))
  end
  -- "baseline" centers the icon on the text's cap-height midline (like
  -- macOS symbol alignment) instead of the text box's geometric center.
  return ui.row({ spacing = options.spacing or space_scale[2], align = options.align or "baseline", children = children })
end

local function build_chip(options, theme)
  local chip_theme = theme and theme.components and theme.components.chip or {}
  local selected = options.selected or false
  local background = options.background or chip_theme.background
  if selected then
    background = options.selected_background or chip_theme.selected_background or background
  end
  local color = options.color or chip_theme.foreground
  if selected then
    color = options.selected_color or chip_theme.selected_foreground or color
  end
  local hover_background = options.hover_background or chip_theme.hover_background
  local pressed_background = options.pressed_background or chip_theme.pressed_background
  if selected then
    hover_background = options.selected_hover_background or chip_theme.selected_hover_background
    pressed_background = options.selected_pressed_background or chip_theme.selected_pressed_background
  end

  local padding = options.padding
  if not padding then
    padding = { x = chip_theme.padding_x or space_scale[2], y = chip_theme.padding_y or space_scale[1] }
  end

  local child = options.child
  if not child then
    if options.icon then
      child = ui.icon_label(options.icon, options.label, {
        size = options.icon_size or options.size or chip_theme.icon_size,
        color = color,
        label_size = options.label_size or chip_theme.font_size,
        font_size = options.font_size or chip_theme.font_size,
        line_height = options.line_height or chip_theme.line_height,
        role = options.role,
        spacing = options.spacing or chip_theme.gap,
      })
    else
      child = ui.label(options.label or "", {
        color = color,
        size = options.label_size or chip_theme.font_size,
        font_size = options.font_size or chip_theme.font_size,
        line_height = options.line_height or chip_theme.line_height,
        role = options.role,
      })
    end
  end
  return ui.gesture({
    id = options.id,
    child = ui.container({
      background = background,
      border = options.border,
      border_width = options.border_width,
      radius = options.radius or chip_theme.radius,
      min_width = options.min_width,
      min_height = options.min_height or chip_theme.min_height,
      align = options.align,
      horizontal_align = options.horizontal_align,
      vertical_align = options.vertical_align or "center",
      padding = padding,
    }, child),
    hover_background = hover_background,
    pressed_background = pressed_background,
    focused_border = options.focused_border or chip_theme.focused_border,
    focused_border_width = options.focused_border_width or chip_theme.focused_border_width,
    cursor = options.cursor,
    activation = options.activation,
    on_tap = options.on_tap,
    on_tap_down = options.on_tap_down,
    on_tap_up = options.on_tap_up,
    on_tap_cancel = options.on_tap_cancel,
  })
end

local Chip = ui.stateful({
  build = function(self, context)
    return build_chip(self.props, self.props.theme or context.theme)
  end,
})

--- Chip metrics and colors come from the ambient theme. Pass `theme` only
--- to intentionally override `theme.components.chip`; explicit style options
--- always win.
function ui.chip(options)
  return Chip(options)
end

local function build_menu(options, theme)
  local menu_theme = theme and theme.components and theme.components.menu or {}
  return ui.container({
    background = options.background or menu_theme.background,
    border = options.border or menu_theme.border,
    border_width = options.border_width or menu_theme.border_width,
    radius = options.radius or menu_theme.radius,
    shadow = options.shadow or menu_theme.shadow,
    padding = options.padding or menu_theme.padding,
    child = options.child,
  })
end

local Menu = ui.stateful({
  build = function(self, context)
    return build_menu(self.props, self.props.theme or context.theme)
  end,
})

--- Menu surface using the ambient `theme.components.menu` colors and metrics.
--- Placement remains the responsibility of ui.popup/ui.anchored.
function ui.menu(options)
  return Menu(options)
end

local function build_menu_item(options, theme)
  local menu_theme = theme and theme.components and theme.components.menu or {}
  local item_theme = menu_theme.item or {}
  local selected = options.selected or false
  local background = options.background
  local hover_background
  if options.hover_background ~= false then
    hover_background = options.hover_background or item_theme.hover_background
  end
  if selected then
    background = options.selected_background or item_theme.selected_background or background
    if options.hover_background ~= false then
      if options.selected_hover_background == false then
        hover_background = nil
      else
        hover_background = options.selected_hover_background or item_theme.selected_hover_background or hover_background
      end
    end
  end
  local padding = options.padding
  if not padding then
    padding = { x = item_theme.padding_x or space_scale[3], y = item_theme.padding_y or control_padding_y }
  end
  local child = ui.default_text_style({
    font_size = item_theme.font_size or font_size_scale[2],
    line_height = item_theme.line_height or line_height_scale[2],
    child = options.child,
  })
  return ui.pressable({
    id = options.id,
    hover_background = hover_background,
    cursor = options.cursor,
    activation = options.activation,
    on_tap = options.on_tap,
    on_hover = options.on_hover,
    child = ui.container({
      background = background,
      radius = options.radius or item_theme.radius,
      min_height = options.min_height or item_theme.min_height,
      padding = padding,
    }, child),
  })
end

local MenuItem = ui.stateful({
  build = function(self, context)
    return build_menu_item(self.props, self.props.theme or context.theme)
  end,
})

--- Interactive row using the ambient `theme.components.menu.item` colors and
--- metrics. `selected` lets keyboard and pointer selection share one highlight.
function ui.menu_item(options)
  return MenuItem(options)
end

local function build_menu_label(options, theme)
  local menu_theme = theme and theme.components and theme.components.menu or {}
  local label_theme = menu_theme.label or {}
  local child = options.child or ui.label(options.text or "", {
    color = options.color or label_theme.foreground,
    font_size = label_theme.font_size or font_size_scale[2],
    line_height = label_theme.line_height or line_height_scale[2],
  })
  if options.child then
    child = ui.default_text_style({
      color = options.color or label_theme.foreground,
      font_size = label_theme.font_size or font_size_scale[2],
      line_height = label_theme.line_height or line_height_scale[2],
      child = child,
    })
  end
  local padding = options.padding
  if not padding then
    padding = { x = label_theme.padding_x or space_scale[3], y = label_theme.padding_y or control_padding_y }
  end
  return ui.container({
    min_height = options.min_height or label_theme.min_height,
    padding = padding,
    child = child,
  })
end

local MenuLabel = ui.stateful({
  build = function(self, context)
    return build_menu_label(self.props, self.props.theme or context.theme)
  end,
})

--- Non-interactive menu row for a group or section name.
function ui.menu_label(options)
  return MenuLabel(options)
end

local function build_menu_separator(options, theme)
  local menu_theme = theme and theme.components and theme.components.menu or {}
  local separator_theme = menu_theme.separator or {}
  return ui.padding({
    x = options.inset or separator_theme.inset or space_scale[1],
    child = ui.separator({
      color = options.color or separator_theme.color,
      thickness = options.thickness or separator_theme.thickness or 1,
      margin = options.margin or separator_theme.margin or space_scale[2],
      axis = options.axis,
    }),
  })
end

local MenuSeparator = ui.stateful({
  build = function(self, context)
    return build_menu_separator(self.props, self.props.theme or context.theme)
  end,
})

--- Themed divider between menu items or groups.
function ui.menu_separator(options)
  return MenuSeparator(options)
end

function ui.icon_button(options)
  return ui.chip({
    id = options.id,
    theme = options.theme,
    icon = options.icon,
    icon_size = options.size or space_scale[4],
    color = options.color,
    background = options.background,
    border = options.border,
    hover_background = options.hover_background,
    pressed_background = options.pressed_background,
    focused_border = options.focused_border,
    focused_border_width = options.focused_border_width,
    selected = options.selected,
    selected_background = options.selected_background,
    selected_color = options.selected_color,
    selected_hover_background = options.selected_hover_background,
    selected_pressed_background = options.selected_pressed_background,
    padding = options.padding or { all = space_scale[2] },
    radius = options.radius,
    on_tap = options.on_tap,
    on_tap_down = options.on_tap_down,
    on_tap_up = options.on_tap_up,
    on_tap_cancel = options.on_tap_cancel,
  })
end

function ui.padding(options)
  options = options or {}
  return {
    type = "padding",
    all = options.all,
    x = options.x,
    y = options.y,
    left = options.left,
    right = options.right,
    top = options.top,
    bottom = options.bottom,
    insets = options.insets or options.padding,
    child = options.child,
  }
end

function ui.center(child)
  return {
    type = "center",
    child = child,
  }
end

function ui.button(options)
  options = options or {}
  return {
    type = "button",
    id = options.id,
    label = options.label,
    on_pressed = options.on_pressed,
  }
end

function ui.action_button(options)
  options = options or {}
  return {
    type = "button",
    id = options.id,
    label = options.label,
    action_id = options.action_id,
  }
end

function ui.actions(options)
  options = options or {}
  return {
    type = "actions",
    bindings = options.bindings,
    child = options.child,
  }
end

function ui.shortcuts(options)
  options = options or {}
  return {
    type = "shortcuts",
    bindings = options.bindings,
    child = options.child,
  }
end

return ui
