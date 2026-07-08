local kw = require("keywork")

local App = kw.stateful({
  init = function(self)
    self.typed = ""
  end,

  build = function(self, state)
    local size = string.format("window: %.0fx%.0f", state.window_width, state.window_height)

    local content = kw.column({
      spacing = 12,
      children = {
        kw.text("Keywork MVP"),
        kw.text(size),
        kw.text("scheme: " .. state.color_scheme),
        kw.text("emoji: 😀 🎉 🚀 ✨ 🇺🇸 👍🏽 👩‍🚀 1️⃣"),
        kw.text("input: " .. self.typed),
        kw.text_input({
          id = "demo-input",
          placeholder = "Type here",
          on_change = function(text)
            self:set_state(function(s)
              s.typed = text
            end)
          end,
        }),
        kw.action_button({ id = "hello", label = "Press me", action_id = "hello" }),
        kw.row({
          spacing = 8,
          children = {
            kw.box({ background = 0xffd5efff }, kw.padding({ all = 6, child = kw.text("fixed") })),
            kw.expanded(kw.box({ background = 0xffd6f1df }, kw.padding({ all = 6, child = kw.text("flex 1") }))),
            kw.expanded(kw.box({ background = 0xffffdbdc }, kw.padding({ all = 6, child = kw.text("flex 2") })), 2),
          },
        }),
        kw.row({
          main_align = "space_between",
          children = {
            kw.text("left"),
            kw.text("middle"),
            kw.text("right"),
          },
        }),
        kw.sized({
          height = 120,
          child = kw.list({
            id = "demo-list",
            count = 10000,
            item_height = 20,
            build_item = function(index)
              return kw.text(string.format("virtual row %d of 10000", index))
            end,
          }),
        }),
        kw.sized({
          height = 120,
          child = kw.scroll({
            id = "demo-scroll",
            child = kw.column({
              spacing = 6,
              children = (function()
                local rows = {}
                for index = 1, 30 do
                  rows[index] = kw.text(string.format("scrollable row %d", index))
                end
                return rows
              end)(),
            }),
          }),
        }),
      },
    })

    return kw.padding({
      all = 24,
      child = kw.actions({
        bindings = {
          hello = function()
            print("hello from Lua")
          end,
        },
        child = kw.shortcuts({
          bindings = {
            enter = "hello",
          },
          child = content,
        }),
      }),
    })
  end,
})

return kw.app({
  child = App({ key = "app" }),
})
