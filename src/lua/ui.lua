local ui = {}

-- Radix Themes scales at 100% scaling and medium radius, mirroring `scale`
-- in src/ui/types.zig. Lua's 1-based arrays match Radix token names:
-- space_scale[3] is Radix --space-3.
local space_scale = { 4, 8, 12, 16, 24, 32, 40, 48, 64 }
local font_size_scale = { 12, 14, 16, 18, 20, 24, 28, 35, 60 }
local line_height_scale = { 16, 20, 24, 26, 28, 30, 36, 40, 60 }
local radius_scale = { 3, 4, 6, 8, 12, 16 }

local default_theme = {
  schemes = {
    light = {
      colors = {
        black = 0xff000000,
        white = 0xffffffff,

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

        red = 0xffe5484d,
        orange = 0xfff76b15,
        yellow = 0xffffe629,
        green = 0xff30a46c,
        mint = 0xff00a2c7,
        teal = 0xff00a2c7,
        cyan = 0xff00a2c7,
        blue = "blue9",
        indigo = 0xff6e56cf,
        purple = 0xff6e56cf,
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
        system_background = "slate2",
        secondary_system_background = "slate1",
        tertiary_system_background = "white",
        system_fill = 0x1700002d,
        secondary_system_fill = 0x0f000033,
        tertiary_system_fill = 0x06000055,
        quaternary_system_fill = 0x03000055,
        separator = "slate7",
        opaque_separator = "slate7",

        background = "system_background",
        surface = "secondary_system_background",
        surface_high = "tertiary_system_background",
        surface_low = "gray6",
        text = "label",
        text_secondary = "secondary_label",
        text_tertiary = "tertiary_label",
        placeholder = "tertiary_label",
        border = "separator",
        fill = "system_fill",
        fill_secondary = "secondary_system_fill",

        accent = "blue",
        on_accent = "white",
        success = "green",
        on_success = "black",
        warning = "yellow",
        on_warning = "black",
        danger = "red",
        on_danger = "black",
        info = "cyan",
        on_info = "black",

        foreground = "text",
        muted = "text_secondary",
        primary = "accent",
        on_primary = "on_accent",
        error = "danger",
        on_error = "on_danger",
      },
    },
    dark = {
      colors = {
        black = 0xff000000,
        white = 0xffffffff,

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

        red = 0xffe5484d,
        orange = 0xfff76b15,
        yellow = 0xffffe629,
        green = 0xff30a46c,
        mint = 0xff00a2c7,
        teal = 0xff00a2c7,
        cyan = 0xff00a2c7,
        blue = "blue9",
        indigo = 0xff6e56cf,
        purple = 0xff6e56cf,
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
        tertiary_system_background = "slate3",
        system_fill = 0x1dd3edf8,
        secondary_system_fill = 0x14ddeaf8,
        tertiary_system_fill = 0x09d8f4f6,
        quaternary_system_fill = 0x00d8f4f6,
        separator = "slate7",
        opaque_separator = "slate7",

        background = "system_background",
        surface = "secondary_system_background",
        surface_high = "tertiary_system_background",
        surface_low = "black",
        text = "label",
        text_secondary = "secondary_label",
        text_tertiary = "tertiary_label",
        placeholder = "tertiary_label",
        border = "separator",
        fill = "system_fill",
        fill_secondary = "secondary_system_fill",

        accent = "blue",
        on_accent = "black",
        success = "green",
        on_success = "black",
        warning = "yellow",
        on_warning = "black",
        danger = "red",
        on_danger = "black",
        info = "cyan",
        on_info = "black",

        foreground = "text",
        muted = "text_secondary",
        primary = "accent",
        on_primary = "on_accent",
        error = "danger",
        on_error = "on_danger",
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
      -- Radix size-2 button: 32px tall, space-3 horizontal padding, radius-2.
      -- Control height is text-driven, so 6px vertical padding approximates
      -- the 32px Radix height at a 14px label size.
      padding_x = space_scale[3],
      padding_y = 6,
      radius = radius_scale[2],
      default = {
        background = "accent",
        foreground = "on_accent",
      },
      hover = {
        background = "text",
        foreground = "background",
      },
      pressed = {
        background = "text",
        foreground = "background",
      },
      disabled = {
        background = "surface_low",
        foreground = "text_secondary",
      },
      focused = {
        border = "accent",
      },
    },

    input = {
      -- Radix size-2 text field: 32px tall, space-2 horizontal padding,
      -- radius-2, font-size-2.
      padding_x = space_scale[2],
      padding_y = 6,
      radius = radius_scale[2],
      font_size = font_size_scale[2],
      background = "surface_high",
      foreground = "text",
      placeholder = "placeholder",
      border = "border",
      focused_border = "accent",
    },

    chip = {
      -- Compact pill control: space-2 horizontal padding, space-1 vertical,
      -- radius-2. Height stays text-driven unless min_height is set.
      padding_x = space_scale[2],
      padding_y = space_scale[1],
      radius = radius_scale[2],
    },

    menu = {
      background = "surface",
      border = "border",
      border_width = 1,
      radius = radius_scale[4],
      padding = space_scale[1],
      item = {
        padding_x = space_scale[3],
        padding_y = space_scale[2],
        radius = radius_scale[4],
        hover_background = "fill_secondary",
        selected_background = "fill",
        selected_hover_background = "fill",
      },
      label = {
        padding_x = space_scale[3],
        padding_y = space_scale[2],
        foreground = "text_secondary",
      },
      separator = {
        color = "border",
        thickness = 1,
        margin = space_scale[1],
      },
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
    background = resolve_color(chip.background, colors),
    foreground = resolve_color(chip.foreground, colors),
    hover_background = resolve_color(chip.hover_background, colors),
    selected_background = resolve_color(chip.selected_background, colors),
    selected_foreground = resolve_color(chip.selected_foreground, colors),
    selected_hover_background = resolve_color(chip.selected_hover_background, colors),
  }
end

local function resolve_menu(menu, colors, space, radius)
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
    item = {
      padding_x = resolve_space(item.padding_x, space),
      padding_y = resolve_space(item.padding_y, space),
      radius = resolve_radius(item.radius, radius),
      hover_background = resolve_color(item.hover_background, colors),
      selected_background = resolve_color(item.selected_background, colors),
      selected_hover_background = resolve_color(item.selected_hover_background, colors),
    },
    label = {
      padding_x = resolve_space(label.padding_x, space),
      padding_y = resolve_space(label.padding_y, space),
      foreground = resolve_color(label.foreground, colors),
    },
    separator = {
      color = resolve_color(separator.color, colors),
      thickness = separator.thickness,
      margin = resolve_space(separator.margin, space),
    },
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
  local components = {
    button = resolve_button(theme.components and theme.components.button, colors, space, radius),
    input = resolve_input(theme.components and theme.components.input, colors, space, radius),
    chip = resolve_chip(theme.components and theme.components.chip, colors, space, radius),
    menu = resolve_menu(theme.components and theme.components.menu, colors, space, radius),
  }

  return {
    color_scheme = color_scheme,
    colors = colors,
    text = copy_table(theme.text or {}),
    space = space,
    font_size = font_size,
    line_height = line_height,
    radius = radius,
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
    child = ui.padding({ insets = options.padding, child = child })
  end
  return ui.box({
    background = options.background,
    border = options.border,
    border_width = options.border_width,
    radius = options.radius,
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
  }
end

function ui.icon_label(icon_name, text, options)
  options = options or {}
  -- No size default here: a nil size falls through to the enclosing
  -- icon_theme context or the bridge's base 16px default.
  local children = { ui.icon({ name = icon_name, size = options.size, color = options.color }) }
  if text and text ~= "" then
    table.insert(children, ui.label(text, { color = options.color, size = options.label_size, font_size = options.font_size, line_height = options.line_height, role = options.role }))
  end
  -- "baseline" centers the icon on the text's cap-height midline (like
  -- macOS symbol alignment) instead of the text box's geometric center.
  return ui.row({ spacing = options.spacing or 6, align = options.align or "baseline", children = children })
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
  if selected then
    hover_background = options.selected_hover_background or chip_theme.selected_hover_background
  end

  local padding = options.padding
  if not padding then
    padding = { x = chip_theme.padding_x or 8, y = chip_theme.padding_y or 4 }
  end

  local child = options.child
  if not child then
    if options.icon then
      child = ui.icon_label(options.icon, options.label, {
        size = options.icon_size or options.size,
        color = color,
        label_size = options.label_size,
        font_size = options.font_size,
        line_height = options.line_height,
        role = options.role,
        spacing = options.spacing,
      })
    else
      child = ui.label(options.label or "", { color = color, size = options.label_size, font_size = options.font_size, line_height = options.line_height, role = options.role })
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
      vertical_align = options.vertical_align,
      padding = padding,
    }, child),
    hover_background = hover_background,
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
    padding = { x = item_theme.padding_x or 12, y = item_theme.padding_y or 8 }
  end
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
      padding = padding,
    }, options.child),
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
  })
  local padding = options.padding
  if not padding then
    padding = { x = label_theme.padding_x or 12, y = label_theme.padding_y or 8 }
  end
  return ui.padding({ insets = padding, child = child })
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
  return ui.separator({
    color = options.color or separator_theme.color,
    thickness = options.thickness or separator_theme.thickness or 1,
    margin = options.margin or separator_theme.margin or 4,
    axis = options.axis,
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
    icon_size = options.size,
    color = options.color,
    background = options.background,
    border = options.border,
    padding = options.padding or { all = 6 },
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
