local kw = require("keywork")

local function viewport_for(story)
  local viewport = story.viewport or {}
  return {
    width = viewport.width or 640,
    height = viewport.height or 480,
    scale = viewport.scale or 1,
  }
end

local Browser = kw.stateful({
  init = function(self)
    self.selected = 1
  end,

  build = function(self, context)
    local book = self.props.book
    local stories = book.stories or {}
    local colors = context.theme.colors
    local selected = stories[self.selected]
    if not selected and #stories > 0 then
      self.selected = 1
      selected = stories[1]
    end

    local story_items = {}
    local previous_group = nil
    for index, story in ipairs(stories) do
      local group = story.group or "Stories"
      if group ~= previous_group then
        story_items[#story_items + 1] = kw.padding({
          left = 12,
          right = 12,
          top = previous_group and 16 or 8,
          bottom = 6,
          child = kw.text(string.upper(group), {
            color = colors.muted,
            font_size = 11,
            max_lines = 1,
          }),
        })
        previous_group = group
      end

      local is_selected = index == self.selected
      story_items[#story_items + 1] = kw.pressable({
        id = "storybook-story:" .. story.id,
        hover_background = colors.fill,
        cursor = "pointer",
        on_tap = function()
          self:set_state(function(state)
            state.selected = index
          end)
        end,
        child = kw.container({
          background = is_selected and colors.blue3 or 0x00000000,
          radius = 6,
          padding = { left = 12, right = 12, top = 8, bottom = 8 },
          child = kw.text(story.name, {
            color = is_selected and colors.blue11 or colors.text,
            max_lines = 1,
          }),
        }),
      })
    end

    if #story_items == 0 then
      story_items[1] = kw.padding({
        all = 12,
        child = kw.text("No stories", { color = colors.muted }),
      })
    end

    local sidebar = kw.container({
      background = colors.surface,
      border = colors.border,
      child = kw.column({
        align = "stretch",
        children = {
          kw.padding({
            left = 16,
            right = 16,
            top = 16,
            bottom = 12,
            child = kw.column({
              spacing = 4,
              children = {
                kw.text(book.title or "Storybook", {
                  color = colors.text,
                  font_size = 18,
                  max_lines = 1,
                }),
                kw.text(string.format("%d %s", #stories, #stories == 1 and "story" or "stories"), {
                  color = colors.muted,
                  font_size = 12,
                }),
              },
            }),
          }),
          kw.separator({ color = colors.border }),
          kw.expanded(kw.scroll({
            id = "storybook-stories",
            child = kw.padding({
              left = 8,
              right = 8,
              bottom = 12,
              child = kw.column({
                align = "stretch",
                children = story_items,
              }),
            }),
          })),
        },
      }),
    })

    local content
    if selected then
      local viewport = viewport_for(selected)
      local scheme = selected.color_scheme or "light"
      local story_context = {
        window_width = viewport.width,
        window_height = viewport.height,
        color_scheme = scheme,
      }
      local preview_theme = kw.theme_for(story_context)
      local story_widget = selected.render(story_context)
      local preview = kw.sized({
        width = viewport.width,
        height = viewport.height,
        child = kw.theme({
          data = preview_theme,
          child = kw.container({
            background = preview_theme.colors.background,
            min_width = viewport.width,
            min_height = viewport.height,
            child = kw.keyed("storybook-preview:" .. selected.id, story_widget),
          }),
        }),
      })

      content = kw.column({
        align = "stretch",
        children = {
          kw.container({
            background = colors.surface,
            border = colors.border,
            padding = { left = 20, right = 20, top = 12, bottom = 12 },
            child = kw.row({
              align = "center",
              children = {
                kw.expanded(kw.column({
                  spacing = 2,
                  children = {
                    kw.text(selected.name, {
                      color = colors.text,
                      font_size = 16,
                      max_lines = 1,
                    }),
                    kw.text(selected.id, {
                      color = colors.muted,
                      font_size = 12,
                      max_lines = 1,
                    }),
                  },
                })),
                kw.text(string.format("%g × %g  ·  %gx  ·  %s", viewport.width, viewport.height, viewport.scale, scheme), {
                  color = colors.muted,
                  font_size = 12,
                  max_lines = 1,
                }),
              },
            }),
          }),
          kw.expanded(kw.container({
            background = colors.surface_low,
            padding = { all = 24 },
            align = "center",
            child = preview,
          })),
        },
      })
    else
      content = kw.center(kw.text("Add a story to begin", { color = colors.muted }))
    end

    return kw.sized({
      width = context.window_width,
      height = context.window_height,
      child = kw.container({
        background = colors.background,
        child = kw.row({
          align = "stretch",
          children = {
            kw.sized({ width = 260, child = sidebar }),
            kw.expanded(content),
          },
        }),
      }),
    })
  end,
})

return function(book)
  return Browser({
    key = "keywork-storybook-browser",
    book = book,
  })
end
