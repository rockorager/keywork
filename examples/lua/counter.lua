-- Counter app: run with `keywork examples/lua/counter.lua`.

local kw = require("kw")

local surface = kw.surface({
  title = "Keywork Lua counter",
  app_id = "dev.keywork.LuaCounter",
  width = 480,
  height = 240,
})

local count = 0
local submit

local function view()
  return {
    type = "padding",
    insets = 24,
    child = {
      type = "column",
      gap = 12,
      { type = "text", value = "Lua counter", role = "title" },
      { type = "text", value = "Count: " .. count },
      {
        type = "filled_button",
        id = "increment",
        on_activate = function()
          count = count + 1
          submit()
        end,
        child = { type = "text", value = "Increment", role = "label" },
      },
    },
  }
end

submit = function()
  surface:submit(view())
end

submit()
