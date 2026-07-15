-- This is a headless policy process; it creates no Wayland surfaces.
local river = require("keywork.river")
local process = require("keywork.process")

local function tile(context)
    local output = context.outputs[1]
    if not output or #context.windows == 0 then
        return {}
    end

    local placements = {}
    local width = math.floor(output.width / #context.windows)
    for index, window in ipairs(context.windows) do
        local x = output.x + (index - 1) * width
        placements[index] = {
            window = window.id,
            x = x,
            y = output.y,
            width = index == #context.windows and output.x + output.width - x or width,
            height = output.height,
        }
    end
    return placements
end

return river.app({
    manager = river.window_manager({
        bindings = {
            ["Super+Return"] = function()
                assert(process.spawn({ argv = { "foot" } }))
            end,
            ["Super+j"] = function()
                assert(river.focus_next())
            end,
            ["Super+q"] = function()
                assert(river.close_focused())
            end,
            ["Super+Shift+e"] = function()
                assert(river.exit_session())
            end,
        },
        layout = tile,
    }),
})
