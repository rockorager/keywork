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

function ui.theme_for(state)
  if state and state.color_scheme == "dark" then
    return { color_scheme = "dark", colors = dark_colors, spacing = { xs = 4, sm = 8, md = 12, lg = 16 } }
  end
  return { color_scheme = "light", colors = light_colors, spacing = { xs = 4, sm = 8, md = 12, lg = 16 } }
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

function ui.theme(data, child)
  return {
    type = "theme",
    theme = data,
    child = child,
  }
end

function ui.default_text_style(style, child)
  style = style or {}
  return {
    type = "default_text_style",
    color = style.color,
    size = style.size,
    font_size = style.font_size,
    child = child,
  }
end

function ui.icon_theme(style, child)
  style = style or {}
  return {
    type = "icon_theme",
    color = style.color,
    size = style.size,
    child = child,
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
    child = ui.padding(options.padding, child)
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

function ui.clickable(id, child, on_click, options)
  options = options or {}
  return {
    type = "clickable",
    id = id,
    child = child,
    on_click = on_click,
    activation = options.activation,
  }
end

function ui.pressable(id, child, on_press)
  return ui.clickable(id, child, on_press, { activation = "press" })
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

function ui.focus(id, child, options)
  options = options or {}
  return {
    type = "focus",
    id = id,
    child = child,
    autofocus = options.autofocus or false,
    skip_traversal = options.skip_traversal or false,
    can_request_focus = options.can_request_focus ~= false,
    on_focus_change = options.on_focus_change,
  }
end

function ui.focus_scope(id, child, options)
  options = options or {}
  return {
    type = "focus_scope",
    id = id,
    child = child,
    modal = options.modal or false,
  }
end

function ui.text_input(id, placeholder)
  return {
    type = "text_input",
    id = id,
    placeholder = placeholder,
  }
end

function ui.column(children, gap)
  local cross_align
  if children.children then
    gap = children.gap
    cross_align = children.cross_align or children.align
    children = children.children
  end
  return {
    type = "column",
    children = children,
    gap = gap or 0,
    cross_align = cross_align,
  }
end

function ui.row(children, gap)
  local cross_align
  if children.children then
    gap = children.gap
    cross_align = children.cross_align or children.align
    children = children.children
  end
  return {
    type = "row",
    children = children,
    gap = gap or 0,
    cross_align = cross_align,
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

function ui.svg_icon(path, size, color)
  return {
    type = "svg_icon",
    path = path,
    size = size,
    color = color,
  }
end

function ui.icon(name, size, color)
  return {
    type = "icon",
    name = name,
    size = size,
    color = color,
  }
end

function ui.icon_label(icon_name, text, options)
  options = options or {}
  local children = { ui.icon(icon_name, options.size or 18, options.color) }
  if text and text ~= "" then
    table.insert(children, ui.label(text, { color = options.color, size = options.label_size, font_size = options.font_size, role = options.role }))
  end
  return ui.row({ gap = options.gap or 6, align = options.align or "center", children = children })
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
        gap = options.gap,
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
    on_tap = options.on_tap or options.on_pressed,
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
    on_tap = options.on_tap or options.on_pressed,
    on_tap_down = options.on_tap_down,
    on_tap_up = options.on_tap_up,
    on_tap_cancel = options.on_tap_cancel,
  })
end

function ui.padding(insets, child)
  return {
    type = "padding",
    insets = insets,
    child = child,
  }
end

function ui.center(child)
  return {
    type = "center",
    child = child,
  }
end

function ui.button(id, label, on_pressed)
  return {
    type = "button",
    id = id,
    label = label,
    on_pressed = on_pressed,
  }
end

function ui.action_button(id, label, action_id)
  return {
    type = "button",
    id = id,
    label = label,
    action_id = action_id,
  }
end

function ui.actions(bindings, child)
  return {
    type = "actions",
    bindings = bindings,
    child = child,
  }
end

function ui.shortcuts(bindings, child)
  return {
    type = "shortcuts",
    bindings = bindings,
    child = child,
  }
end

return ui
