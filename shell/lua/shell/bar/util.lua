local kw = require("keywork")

local M = {}

local function trim(value)
    local trimmed = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return trimmed
end

local function label(value, color)
    return kw.text(value, { color = color })
end

local function status_pill(id, icon_name, text, color, options)
    options = options or {}
    if options.on_activate then
        return kw.icon_button({
            id = id,
            icon = icon_name,
            size = "medium",
            appearance = "subtle",
            tone = options.tone,
            on_activate = options.on_activate,
        })
    end
    local children = {}
    if text and text ~= "" then
        children[#children + 1] = kw.text(text, { color = color, font_size = 12, line_height = 16 })
    end
    children[#children + 1] = kw.icon({ name = icon_name, size = 20, color = color })
    return kw.container({
        min_height = 32,
        vertical_align = "center",
        child = kw.row({ spacing = 6, align = "cap_center", children = children }),
    })
end

M.trim = trim
M.label = label
M.status_pill = status_pill

return M
