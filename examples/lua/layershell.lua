local ui = require("ui")
local keywork = require("keywork")

local colors = {
  background = 0xff111113,
  text = 0xffedeef0,
  accent = 0xff0090ff,
}

-- The script declares its own window; CLI flags override it, so
-- `--backend=vulkan` or `--backend=log` still work for debugging.
--
-- Run with:
--   zig build run-lua-layershell-example
--   zig build run-lua-vulkan-layershell-example
-- or:
--   zig build run -- examples/lua/layershell.lua
keywork.window({
  app_id = "dev.keywork.LayerShellExample",
  backend = "cpu",
  height = 32,
  layer_shell = {
    layer = "top",
    anchor = { "top", "left", "right" },
    exclusive_zone = 32,
  },
})
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
