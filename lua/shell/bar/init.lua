local kw = require("keywork")

local colors = require("shell.bar.colors")
local status = require("shell.bar.status")
local tray = require("shell.bar.tray")
local workspaces = require("shell.bar.workspaces")

local M = {}

M.height = 40

-- A stable palette identity keeps child update() hooks from refreshing on
-- rebuilds that did not change colors. Include resolved color values so live
-- theme or accent changes within one light/dark scheme replace the palette.
local cached_palette_key
local cached_palette
local function palette_key(theme)
    local entries = {}
    for name, value in pairs(theme.colors or {}) do
        if type(value) == "number" then
            entries[#entries + 1] = name .. "=" .. value
        end
    end
    table.sort(entries)
    return theme.color_scheme .. ":" .. table.concat(entries, ",")
end

local function palette_for(theme)
    local key = palette_key(theme)
    if cached_palette_key ~= key then
        cached_palette_key = key
        cached_palette = colors.palette(theme)
    end
    return cached_palette
end

-- One bar per output. props: output and show_tray (SNI hosts register on
-- D-Bus, so only one bar carries it).
local Bar = kw.stateful({
    build = function(self, context)
        local theme = context.theme
        local palette = palette_for(theme)

        local children = {
            workspaces.Workspaces({
                key = "workspaces",
                colors = palette,
                output = self.props.output,
            }),
            kw.spacer(),
        }
        if self.props.show_tray then
            children[#children + 1] = tray.Items({ key = "tray", colors = palette })
        end
        children[#children + 1] = status.Items({
            key = "status",
            colors = palette,
            on_open_audio_settings = self.props.on_open_audio_settings,
        })

        return kw.theme({
            data = palette.theme,
            child = kw.column({
                align = "stretch",
                children = {
                    kw.expanded({ child =
                        kw.container({
                            background = palette.background,
                            vertical_align = "center",
                            padding = { x = theme.space[2], y = theme.space[1] },
                            child = kw.row({
                                spacing = theme.space[3],
                                align = "center",
                                children = children,
                            }),
                        })
                    }),
                    kw.separator({}),
                },
            }),
        })
    end,
})

M.Bar = Bar

return M
