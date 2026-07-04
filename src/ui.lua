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

function ui.clickable(id, child)
  return {
    type = "clickable",
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

function ui.button(id, label)
  return ui.clickable(id, ui.box({ background = 0xff6d4aff },
    ui.padding(8, ui.text(label, { color = 0xffffffff }))))
end

return ui
