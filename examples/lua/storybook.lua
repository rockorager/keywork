local kw = require("keywork")
local sb = require("keywork.storybook")

local function phrase(value)
  local result = value:gsub(" ", "\194\160")
  return result
end

local line_breaking_sample = table.concat({
  table.concat({
    phrase("ALPHA occupies almost half of a carefully measured line for reading"),
    phrase("BRAVO fits beside it"),
    phrase("CHARLIE keeps its neighboring thought"),
    phrase("DELTA closes with a deliberately substantial phrase at the end"),
  }, " "),
  table.concat({
    phrase("HARBOR carries a broad opening phrase across the page"),
    phrase("LANTERN follows quietly"),
    phrase("MEADOW keeps this nearby clause"),
    phrase("RIVER ends the paragraph with another intentionally weighty phrase"),
  }, " "),
}, "\n\n")

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
      id = "text/line-breaking",
      group = "Text",
      name = "Line breaking",
      viewport = { width = 1376, height = 480 },
      render = function(context)
        local theme = kw.theme_for(context)

        local function sample(title, detail, line_break)
          return kw.sized({
            width = 640,
            child = kw.container({
              background = theme.colors.surface,
              border = theme.colors.border,
              radius = 8,
              padding = { all = 20 },
              child = kw.column({
                spacing = 10,
                children = {
                  kw.text(title, { role = "title", max_lines = 1 }),
                  kw.text(detail, { color = theme.colors.muted, role = "label" }),
                  kw.text(line_breaking_sample, { font_size = 14, line_height = 20, line_break = line_break }),
                },
              }),
            }),
          })
        end

        return kw.padding({
          all = 24,
          child = kw.row({
            spacing = 24,
            align = "start",
            children = {
              sample("Greedy", "Current line-by-line wrapping"),
              sample("Knuth–Plass", "Paragraph-wide optimized wrapping", "knuth_plass"),
            },
          }),
        })
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
