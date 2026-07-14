local kw = require("keywork")

local function viewport_for(story)
    local viewport = story.viewport or {}
    local content_height = viewport.height == "content"
    return {
        width = viewport.width or 640,
        height = content_height and 480 or (viewport.height or 480),
        content_height = content_height,
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
        local theme = context.theme
        local colors = theme.colors
        local space = theme.space
        local font_size = theme.font_size
        local line_height = theme.line_height
        local menu = theme.components.menu
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
                    left = menu.label.padding_x,
                    right = menu.label.padding_x,
                    top = menu.label.padding_y + (previous_group and space[2] or 0),
                    bottom = menu.label.padding_y,
                    child = kw.text(string.upper(group), {
                        color = menu.label.foreground,
                        font_size = menu.label.font_size,
                        line_height = menu.label.line_height,
                        max_lines = 1,
                    }),
                })
                previous_group = group
            end

            local is_selected = index == self.selected
            story_items[#story_items + 1] = kw.pressable({
                id = "storybook-story:" .. story.id,
                hover_background = menu.item.hover_background,
                cursor = "pointer",
                on_tap = function()
                    self:set_state(function(state)
                        state.selected = index
                    end)
                end,
                child = kw.container({
                    background = is_selected and menu.item.selected_background or 0x00000000,
                    radius = menu.item.radius,
                    min_height = menu.item.min_height,
                    padding = { x = menu.item.padding_x, y = menu.item.padding_y },
                    child = kw.text(story.name, {
                        color = colors.text,
                        font_size = menu.item.font_size,
                        line_height = menu.item.line_height,
                        max_lines = 1,
                    }),
                }),
            })
        end

        if #story_items == 0 then
            story_items[1] = kw.padding({
                all = space[3],
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
                        left = space[4],
                        right = space[4],
                        top = space[4],
                        bottom = space[3],
                        child = kw.column({
                            spacing = space[1],
                            children = {
                                kw.text(book.title or "Storybook", {
                                    color = colors.text,
                                    font_size = font_size[4],
                                    line_height = line_height[4],
                                    max_lines = 1,
                                }),
                                kw.text(string.format("%d %s", #stories, #stories == 1 and "story" or "stories"), {
                                    color = colors.muted,
                                    font_size = font_size[1],
                                    line_height = line_height[1],
                                }),
                            },
                        }),
                    }),
                    kw.separator({}),
                    kw.expanded(
                        kw.scroll({
                            id = "storybook-stories",
                            child = kw.padding({
                                left = space[2],
                                right = space[2],
                                bottom = space[3],
                                child = kw.column({
                                    align = "stretch",
                                    children = story_items,
                                }),
                            }),
                        })
                    ),
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
            local preview_container = {
                background = preview_theme.colors.background,
                min_width = viewport.width,
                child = kw.keyed("storybook-preview:" .. selected.id, story_widget),
            }
            local preview_options = {
                width = viewport.width,
            }
            if not viewport.content_height then
                preview_container.min_height = viewport.height
                preview_options.height = viewport.height
            end
            preview_options.child = kw.theme({
                data = preview_theme,
                child = kw.container(preview_container),
            })
            local preview = kw.sized(preview_options)

            content = kw.column({
                align = "stretch",
                children = {
                    kw.container({
                        background = colors.surface,
                        border = colors.border,
                        padding = { x = space[5], y = space[3] },
                        child = kw.row({
                            align = "center",
                            children = {
                                kw.expanded(
                                    kw.column({
                                        spacing = space[1],
                                        children = {
                                            kw.text(selected.name, {
                                                color = colors.text,
                                                font_size = font_size[3],
                                                line_height = line_height[3],
                                                max_lines = 1,
                                            }),
                                            kw.text(selected.id, {
                                                color = colors.muted,
                                                font_size = font_size[1],
                                                line_height = line_height[1],
                                                max_lines = 1,
                                            }),
                                        },
                                    })
                                ),
                                kw.text(string.format(
                                    "%g × %s  ·  %gx  ·  %s",
                                    viewport.width,
                                    viewport.content_height and "content" or string.format("%g", viewport.height),
                                    viewport.scale,
                                    scheme
                                ), {
                                    color = colors.muted,
                                    font_size = font_size[1],
                                    line_height = line_height[1],
                                    max_lines = 1,
                                }),
                            },
                        }),
                    }),
                    kw.expanded(
                        kw.container({
                            background = colors.surface_low,
                            padding = { all = space[5] },
                            align = "center",
                            child = preview,
                        })
                    ),
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
