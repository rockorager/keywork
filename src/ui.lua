local ui = {}

local default_theme = {
  schemes = {
    light = {
      colors = {
        black = 0xff000000,
        white = 0xffffffff,

        red = 0xffff3b30,
        orange = 0xffff9500,
        yellow = 0xffffcc00,
        green = 0xff34c759,
        mint = 0xff00c7be,
        teal = 0xff30b0c7,
        cyan = 0xff32ade6,
        blue = 0xff007aff,
        indigo = 0xff5856d6,
        purple = 0xffaf52de,
        pink = 0xffff2d55,
        brown = 0xffa2845e,
        gray = 0xff8e8e93,
        gray2 = 0xffaeaeb2,
        gray3 = 0xffc7c7cc,
        gray4 = 0xffd1d1d6,
        gray5 = 0xffe5e5ea,
        gray6 = 0xfff2f2f7,

        label = "black",
        secondary_label = 0x993c3c43,
        tertiary_label = 0x4c3c3c43,
        quaternary_label = 0x2e3c3c43,
        system_background = "white",
        secondary_system_background = "gray6",
        tertiary_system_background = "white",
        system_fill = 0x33787880,
        secondary_system_fill = 0x29787880,
        tertiary_system_fill = 0x1f787880,
        quaternary_system_fill = 0x14747480,
        separator = 0x4a3c3c43,
        opaque_separator = 0xffc6c6c8,

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

        red = 0xffff453a,
        orange = 0xffff9f0a,
        yellow = 0xffffd60a,
        green = 0xff30d158,
        mint = 0xff63e6e2,
        teal = 0xff40c8e0,
        cyan = 0xff64d2ff,
        blue = 0xff0a84ff,
        indigo = 0xff5e5ce6,
        purple = 0xffbf5af2,
        pink = 0xffff375f,
        brown = 0xffac8e68,
        gray = 0xff8e8e93,
        gray2 = 0xff636366,
        gray3 = 0xff48484a,
        gray4 = 0xff3a3a3c,
        gray5 = 0xff2c2c2e,
        gray6 = 0xff1c1c1e,

        label = "white",
        secondary_label = 0x99ebebf5,
        tertiary_label = 0x4cebebf5,
        quaternary_label = 0x2eebebf5,
        system_background = "black",
        secondary_system_background = "gray6",
        tertiary_system_background = "gray5",
        system_fill = 0x5c787880,
        secondary_system_fill = 0x52787880,
        tertiary_system_fill = 0x3d767680,
        quaternary_system_fill = 0x2e747480,
        separator = 0x99545458,
        opaque_separator = 0xff38383a,

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
    body = { size = 16 },
    label = { size = 14 },
    title = { size = 20 },
  },

  space = { xs = 4, sm = 8, md = 12, lg = 16, xl = 24 },
  radius = { sm = 4, md = 8, lg = 12, full = 999 },

  components = {
    button = {
      padding_x = "md",
      padding_y = "sm",
      radius = "md",
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
      padding_x = "md",
      padding_y = "sm",
      radius = "md",
      background = "surface_high",
      foreground = "text",
      placeholder = "placeholder",
      border = "border",
      focused_border = "accent",
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
  return merge_table(default_theme, options or {})
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
    background = resolve_color(input.background, colors),
    foreground = resolve_color(input.foreground, colors),
    placeholder = resolve_color(input.placeholder, colors),
    border = resolve_color(input.border, colors),
    focused_border = resolve_color(input.focused_border, colors),
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
  local radius = copy_table(theme.radius or {})
  local components = {
    button = resolve_button(theme.components and theme.components.button, colors, space, radius),
    input = resolve_input(theme.components and theme.components.input, colors, space, radius),
  }

  return {
    color_scheme = color_scheme,
    colors = colors,
    text = copy_table(theme.text or {}),
    space = space,
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
    role = style.role,
  }
end

function ui.label(value, options)
  options = options or {}
  return ui.text(value, { color = options.color, size = options.size, font_size = options.font_size, role = options.role or "label" })
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
    on_tap = options.on_tap,
    on_tap_down = options.on_tap_down,
    on_tap_up = options.on_tap_up,
    on_tap_cancel = options.on_tap_cancel,
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

function ui.spacer(flex)
  return {
    type = "spacer",
    flex = flex or 1,
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
    width = options.width,
    height = options.height,
    size = options.size,
    format = options.format,
    pixels = options.pixels,
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
  local children = { ui.icon({ name = icon_name, size = options.size or 18, color = options.color }) }
  if text and text ~= "" then
    table.insert(children, ui.label(text, { color = options.color, size = options.label_size, font_size = options.font_size, role = options.role }))
  end
  return ui.row({ spacing = options.spacing or 6, align = options.align or "center", children = children })
end

function ui.chip(options)
  local child = options.child
  if not child then
    if options.icon then
      child = ui.icon_label(options.icon, options.label, {
        size = options.icon_size or options.size,
        color = options.color,
        label_size = options.label_size,
        font_size = options.font_size,
        role = options.role,
        spacing = options.spacing,
      })
    else
      child = ui.label(options.label or "", { color = options.color, size = options.label_size, font_size = options.font_size, role = options.role })
    end
  end
  return ui.gesture({
    id = options.id,
    child = ui.container({
      background = options.background,
      border = options.border,
      border_width = options.border_width,
      radius = options.radius,
      min_width = options.min_width,
      min_height = options.min_height,
      align = options.align,
      horizontal_align = options.horizontal_align,
      vertical_align = options.vertical_align,
      padding = options.padding or { x = 8, y = 4 },
    }, child),
    on_tap = options.on_tap,
    on_tap_down = options.on_tap_down,
    on_tap_up = options.on_tap_up,
    on_tap_cancel = options.on_tap_cancel,
  })
end

function ui.icon_button(options)
  return ui.chip({
    id = options.id,
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
