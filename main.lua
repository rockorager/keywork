local ui = require("ui")

local App = ui.stateful({
  init = function(self)
    self.typed = ""
  end,

  build = function(self, state)
    local size = string.format("window: %.0fx%.0f", state.window_width, state.window_height)

    local content = ui.column({
      spacing = 12,
      children = {
        ui.text("Keywork MVP"),
        ui.text(size),
        ui.text("scheme: " .. state.color_scheme),
        ui.text("input: " .. self.typed),
        ui.text_input({
          id = "demo-input",
          placeholder = "Type here",
          on_change = function(text)
            self:set_state(function(s)
              s.typed = text
            end)
          end,
        }),
        ui.action_button({ id = "hello", label = "Press me", action_id = "hello" }),
        ui.sized({
          height = 120,
          child = ui.scroll({
            id = "demo-scroll",
            child = ui.column({
              spacing = 6,
              children = (function()
                local rows = {}
                for index = 1, 30 do
                  rows[index] = ui.text(string.format("scrollable row %d", index))
                end
                return rows
              end)(),
            }),
          }),
        }),
      },
    })

    return ui.padding({
      all = 24,
      child = ui.actions({
        bindings = {
          hello = function()
            print("hello from Lua")
          end,
        },
        child = ui.shortcuts({
          bindings = {
            enter = "hello",
          },
          child = content,
        }),
      }),
    })
  end,
})

return App({ key = "app" })
