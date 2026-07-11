local kw = require("keywork")
local sb = require("keywork.storybook")

return sb.book({
  title = "Keywork example stories",
  stories = {
    sb.story({
      id = "text/hello",
      group = "Text",
      name = "Hello",
      viewport = { width = 320, height = 180 },
      render = function()
        return kw.center(kw.text("Hello from Storybook"))
      end,
    }),
    sb.story({
      id = "button/dark",
      group = "Button",
      name = "Dark",
      viewport = { width = 320, height = 180, scale = 2 },
      color_scheme = "dark",
      render = function()
        return kw.center(kw.button({
          id = "example-button",
          label = "Ship it",
          on_pressed = function() end,
        }))
      end,
    }),
  },
})
