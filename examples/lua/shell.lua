local kw = require("keywork")
local loop = require("keywork.loop")

-- Seed of the keywork-shell example: a bar that grows into a full
-- desktop shell (bar + menus + launcher) as multi-window support lands.
--
-- Roadmap markers below track the declarative window design:
--   [windows]  the app returns kw.window nodes keyed by id, one per
--              output, replacing the layer_shell output="all" option
--   [popups]   the clock opens a calendar via kw.anchored/kw.popup
--   [launcher] a launcher window toggled by state, not a process
--
-- Run with:
--   zig build run-lua-shell-example
-- or:
--   zig build run -- examples/lua/shell.lua

local colors = {
  background = 0xf0111113,
  text = 0xffedeef0,
  muted = 0xff797b86,
  accent = 0xff0090ff,
}

local function seconds_until_next_minute()
  local now = os.date("*t")
  return 60 - now.sec
end

local Clock = kw.stateful({
  init = function(self)
    self:update_time()
    self.timer = loop.timer({ delay = seconds_until_next_minute(), interval = 60.0 })
    local timer = self.timer
    loop.spawn(function()
      for _ in timer:ticks() do
        self:set_state(function(state)
          state:update_time()
        end)
      end
    end)
  end,

  dispose = function(self)
    if self.timer then
      self.timer:cancel()
    end
  end,

  update_time = function(self)
    self.time = os.date("%a %b %d  %I:%M %p")
  end,

  build = function(self)
    -- [popups] This gesture becomes a kw.anchored host: clicking
    -- toggles state.menu_open and the calendar hangs off this cell.
    -- Until then, toggling just accents the clock.
    return kw.gesture({
      id = "clock",
      on_tap = function()
        self:set_state(function(state)
          state.menu_open = not state.menu_open
        end)
      end,
      child = kw.text(self.time, {
        color = self.menu_open and colors.accent or colors.text,
      }),
    })
  end,
})

local Bar = kw.stateful({
  build = function(self, state)
    return kw.container({
      background = colors.background,
      padding = { left = 12, right = 12, top = 4, bottom = 4 },
      child = kw.row({
        spacing = 12,
        align = "center",
        children = {
          -- [launcher] becomes a gesture that toggles the launcher
          -- window in app state.
          kw.text("keywork", { color = colors.muted }),
          kw.spacer(),
          Clock({ key = "clock" }),
        },
      }),
    })
  end,
})

-- [windows] This app table becomes a build function returning one
-- kw.window per entry in the outputs list of the app build context.
return kw.app({
  app_id = "dev.keywork.Shell",
  backend = "cpu",
  width = 0, -- stretch to the anchored edges
  height = 32,
  layer_shell = {
    layer = "top",
    anchor = { "top", "left", "right" },
    exclusive_zone = 32,
    output = "all",
  },
  child = Bar({ key = "bar" }),
})
