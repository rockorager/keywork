local ui = require("ui")

local colors = {
  background = 0xff202024,
  foreground = 0xffffffff,
  accent = 0xff9b86ff,
}

-- Run with:
--   zig build run-lua-layershell-example
--   zig build run-lua-vulkan-layershell-example
-- or:
--   zig build run -- --script=examples/lua/layershell.lua --layer-shell --anchor=top,left,right --height=32 --exclusive-zone=32
--   zig build run -- --script=examples/lua/layershell.lua --backend=vulkan --layer-shell --anchor=top,left,right --height=32 --exclusive-zone=32
local App = ui.stateful({
  build = function(self, state)
    local label = string.format(
      "Keywork layer shell  •  %.0fx%.0f  •  scheme: %s",
      state.window_width,
      state.window_height,
      state.color_scheme
    )

    return ui.box({ background = colors.background },
      ui.padding(8,
        ui.text(label, { color = colors.foreground })
      )
    )
  end,
})

return App({ key = "app" })
