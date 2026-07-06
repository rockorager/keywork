local ui = require("ui")

local colors = {
  background = 0xff0c0e12,
  text = 0xfff5f6fa,
  accent = 0xff6cacff,
}

-- Run with:
--   zig build run-lua-layershell-example
--   zig build run-lua-vulkan-layershell-example
-- or:
--   zig build run -- --script=examples/lua/layershell.lua --layer-shell --anchor=top,left,right --height=32 --exclusive-zone=32
--   zig build run -- --script=examples/lua/layershell.lua --backend=vulkan --layer-shell --anchor=top,left,right --height=32 --exclusive-zone=32
local App = ui.stateful({
  build = function(self, state)
    local theme = ui.resolve_theme(ui.theme_data({
      schemes = {
        light = {
          colors = {
            accent = colors.accent,
            surface = colors.background,
            text = colors.text,
          },
        },
        dark = {
          colors = {
            accent = colors.accent,
            surface = colors.background,
            text = colors.text,
          },
        },
      },
    }), state)
    local label = string.format(
      "Keywork layer shell  •  %.0fx%.0f  •  scheme: %s",
      state.window_width,
      state.window_height,
      state.color_scheme
    )

    return ui.theme({
      data = theme,
      child = ui.box({ background = theme.colors.surface },
        ui.padding({
          all = 8,
          child = ui.text(label, { color = theme.colors.text }),
        })
      ),
    })
  end,
})

return App({ key = "app" })
