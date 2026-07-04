local ui = require("ui")

return function(state)
  local status = state.button_pressed and "button pressed" or "button idle"
  local size = string.format("window: %.0fx%.0f", state.window_width, state.window_height)

  return ui.padding(24, ui.column({
    ui.text("Keywork MVP"),
    ui.text(size),
    ui.text("scheme: " .. state.color_scheme),
    ui.text("input: " .. state.input_text),
    ui.text_input("demo-input", "Type here"),
    ui.button("hello", status, state.button_pressed),
  }, 12))
end
