local ui = {}

local light_colors = {
  primary = 0xff6d4aff,
  on_primary = 0xffffffff,
  surface = 0xfff5f3ef,
  on_surface = 0xff1b1b1f,
  surface_variant = 0xffffffff,
  on_surface_variant = 0xff1b1b1f,
  outline = 0xff1b1b1f,
  error = 0xffba1a1a,
  on_error = 0xffffffff,
}

local dark_colors = {
  primary = 0xff9b86ff,
  on_primary = 0xff000000,
  surface = 0xff202024,
  on_surface = 0xffffffff,
  surface_variant = 0xff2b2b30,
  on_surface_variant = 0xffffffff,
  outline = 0xff9b86ff,
  error = 0xffffb4ab,
  on_error = 0xff690005,
}

local default_spacing = { xs = 4, sm = 8, md = 12, lg = 16 }

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
  local color_scheme = options.color_scheme or "light"
  local base_colors = color_scheme == "dark" and dark_colors or light_colors
  return {
    color_scheme = color_scheme,
    colors = merge_table(base_colors, options.colors),
    text = merge_table({}, options.text),
    button = merge_table({}, options.button),
    input = merge_table({}, options.input),
    spacing = merge_table(default_spacing, options.spacing),
  }
end

function ui.theme_for(state)
  local color_scheme = state and state.color_scheme or "light"
  return ui.theme_data({ color_scheme = color_scheme })
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
  }
end

function ui.column(options)
  options = options or {}
  return {
    type = "column",
    children = options.children,
    spacing = options.spacing or 0,
    align = options.align,
  }
end

function ui.row(options)
  options = options or {}
  return {
    type = "row",
    children = options.children,
    spacing = options.spacing or 0,
    align = options.align,
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
