local ui = require("ui")

local App = ui.stateful({
  build = function(self, state)
    local size = string.format("window: %.0fx%.0f", state.window_width, state.window_height)

    local content = ui.column({
      spacing = 12,
      children = {
        ui.text("Keywork MVP"),
        ui.text(size),
        ui.text("scheme: " .. state.color_scheme),
        ui.text("input: " .. state.input_text),
        ui.text_input("demo-input", "Type here"),
        ui.action_button("hello", "Press me", "hello"),
      },
    })

    return ui.padding({
      all = 24,
      child = ui.actions({
        hello = function()
          print("hello from Lua")
        end,
      }, ui.shortcuts({
        enter = "hello",
      }, content)),
    })
  end,
})

return App({ key = "app" })
