local ui = {}

local default_theme = {
  schemes = {
    light = {
      colors = {
        background = 0xfffdfbf7,
        foreground = 0xff1b1b1f,
        primary = 0xff6d4aff,
        on_primary = 0xffffffff,
        surface = 0xfff5f3ef,
        surface_high = 0xffffffff,
        surface_low = 0xffeeeae4,
        border = 0xff8c8991,
        muted = 0xff77737d,
        error = 0xffba1a1a,
        on_error = 0xffffffff,
      },
    },
    dark = {
      colors = {
        background = 0xff111114,
        foreground = 0xfff5f3f7,
        primary = 0xff9b86ff,
        on_primary = 0xff000000,
        surface = 0xff202024,
        surface_high = 0xff2b2b30,
        surface_low = 0xff17171a,
        border = 0xff8f8a99,
        muted = 0xffb7b3c1,
        error = 0xffffb4ab,
        on_error = 0xff690005,
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
        background = "primary",
        foreground = "on_primary",
      },
      hover = {
        background = "foreground",
        foreground = "background",
      },
      pressed = {
        background = "foreground",
        foreground = "background",
      },
      disabled = {
        background = "surface_low",
        foreground = "muted",
      },
      focused = {
        border = "primary",
      },
    },

    input = {
      padding_x = "md",
      padding_y = "sm",
      radius = "md",
      background = "surface_high",
      foreground = "foreground",
      placeholder = "muted",
      border = "border",
      focused_border = "primary",
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
  local colors = copy_table(scheme.colors)
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
