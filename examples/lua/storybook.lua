local kw = require("keywork")
local sb = require("keywork.storybook")

return sb.book({
  title = "Keywork example stories",
  stories = {
    sb.story({
      id = "text/hello",
      group = "Text",
      name = "Hello",
      viewport = { width = 320, height = "content" },
      render = function()
        return kw.padding({ all = 24, child = kw.text("Hello from Storybook") })
      end,
    }),
    sb.story({
      id = "text/wrapping",
      group = "Text",
      name = "Wrapping",
      viewport = { width = 360, height = 240 },
      render = function(context)
        local theme = kw.theme_for(context)
        return kw.center(kw.sized({
          width = 240,
          child = kw.container({
            background = theme.colors.surface,
            border = theme.colors.border,
            radius = 8,
            padding = { all = 16 },
            child = kw.text("Unicode line breaking keeps words together while allowing unusuallylongcontentwithoutbreaks to wrap safely."),
          }),
        }))
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
