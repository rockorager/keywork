return function(state)
  local status = state.button_pressed and "button pressed" or "button idle"

  return ui.padding(24, ui.column({
    ui.text("Keywork MVP"),
    ui.text("input: " .. state.input_text),
    ui.text_input("demo-input", "Type here"),
    ui.button("hello", status),
  }, 12))
end
