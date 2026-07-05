local ui = {}

function ui.text(value, style)
  style = style or {}
  return {
    type = "text",
    value = value,
    color = style.color,
  }
end

function ui.keyed(key, child)
  return {
    type = "keyed",
    key = key,
    child = child,
  }
end

function ui.box(style, child)
  style = style or {}
  return {
    type = "box",
    background = style.background,
    child = child,
  }
end

function ui.clickable(id, child, on_click)
  return {
    type = "clickable",
    id = id,
    child = child,
    on_click = on_click,
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
  return {
    type = "column",
    children = children,
    gap = gap or 0,
  }
end

function ui.row(children, gap)
  return {
    type = "row",
    children = children,
    gap = gap or 0,
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
    size = size or 16,
    color = color,
  }
end

function ui.icon(name, size, color)
  return {
    type = "icon",
    name = name,
    size = size or 16,
    color = color,
  }
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
