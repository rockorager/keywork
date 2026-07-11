local kw = require("keywork")

-- Demo of the runtime's demand-driven animations:
--
--   [spinner]    a free-running sweep that demands a frame per vblank
--                while mounted and costs nothing when absent
--   [scrollbar]  the thumb rests hidden, shows on scroll activity, and
--                fades back out after a short hold
--
-- Run with:
--   zig build run -- examples/lua/animations.lua

local function rows()
  local children = {}
  for index = 1, 60 do
    children[#children + 1] = kw.label("row " .. index)
  end
  return children
end

local App = kw.stateful({
  build = function(self, context)
    return kw.container({ padding = { all = 12 } }, kw.row({
      spacing = 24,
      children = {
        kw.column({
          spacing = 12,
          children = {
            kw.label("spinner"),
            kw.spinner({ size = 28 }),
            kw.spinner({ size = 20, period_ms = 500 }),
          },
        }),
        kw.expanded(kw.column({
          spacing = 12,
          -- Stretch the viewport to the full column width; otherwise it
          -- shrink-wraps the narrow rows and the thumb sits on the text.
          align = "stretch",
          children = {
            kw.label("scroll to reveal the thumb"),
            kw.expanded(kw.scroll({
              id = "demo",
              child = kw.column({ spacing = 4, children = rows() }),
            })),
          },
        })),
      },
    }))
  end,
})

return kw.app({
  app_id = "dev.keywork.AnimationsExample",
  backend = "cpu",
  child = App({ key = "app" }),
  width = 420,
  height = 320,
})
