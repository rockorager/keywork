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
    on_focus_change = options.on_focus_change,
  }
end

function ui.focus_scope(id, child)
  return {
    type = "focus_scope",
    id = id,
    child = child,
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
