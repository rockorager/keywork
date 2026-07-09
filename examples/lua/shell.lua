local kw = require("keywork")
local loop = require("keywork.loop")

-- Seed of the keywork-shell example: a bar that grows into a full
-- desktop shell (bar + menus + launcher).
--
--   [windows]  the app's windows(ctx) function returns kw.window nodes
--              keyed by id, one bar per output; outputs hotplug just
--              rebuilds the window set
--   [popups]   the clock opens a menu via kw.anchored/kw.popup
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

  build_menu = function(self)
    local function item(label)
      return kw.gesture({
        id = "menu-" .. label,
        hover_background = 0xff2a2c31,
        on_tap = function()
          self:set_state(function(state)
            state.menu_open = false
          end)
        end,
        child = kw.padding({
          x = 12,
          y = 6,
          child = kw.text(label, { color = colors.text }),
        }),
      })
    end
    return kw.container({
      background = colors.background,
      radius = 6,
      padding = 4,
      child = kw.column({
        children = {
          kw.padding({
            x = 12,
            y = 6,
            child = kw.text(os.date("%A, %B %d %Y"), { color = colors.muted }),
          }),
          item("Calendar"),
          item("Clock settings"),
        },
      }),
    })
  end,

  build = function(self)
    -- [popups] Clicking the clock toggles menu_open; the popup's
    -- existence follows that state, so the compositor dismissing it
    -- (on_close) and tapping an item both just clear the flag.
    return kw.anchored({
      id = "clock",
      popup = self.menu_open and kw.popup({
        edge = "bottom",
        alignment = "end",
        gap = 4,
        content = function()
          return self:build_menu()
        end,
        on_close = function()
          self:set_state(function(state)
            state.menu_open = false
          end)
        end,
      }) or nil,
      child = kw.gesture({
        id = "clock-tap",
        on_tap = function()
          self:set_state(function(state)
            state.menu_open = not state.menu_open
          end)
        end,
        child = kw.text(self.time, {
          color = self.menu_open and colors.accent or colors.text,
        }),
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

-- [windows] One bar per output, each its own window with its own
-- runtime and popups. Plugging or unplugging a monitor re-runs this
-- function and the window set is diffed by id.
return kw.app({
  app_id = "dev.keywork.Shell",
  backend = "cpu",
  windows = function(ctx)
    local windows = {}
    for _, output in ipairs(ctx.outputs) do
      windows[#windows + 1] = kw.window({
        id = "bar:" .. output.name,
        output = output.name,
        width = 0, -- stretch to the anchored edges
        height = 32,
        layer_shell = {
          layer = "top",
          anchor = { "top", "left", "right" },
          exclusive_zone = 32,
        },
        child = Bar({ key = "bar" }),
      })
    end
    return windows
  end,
})
