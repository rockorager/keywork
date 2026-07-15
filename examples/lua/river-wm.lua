-- This policy chooses tiling and focus-follows-interaction. Keywork only
-- translates the returned commands into legal River protocol transactions.
local river = require("keywork.river")
local process = require("keywork.process")

local focused = {}
local focus_next = {}
local close_focused = {}
local exit_session = false

local function contains_window(context, id)
    for _, window in ipairs(context.windows) do
        if window.id == id then
            return true
        end
    end
    return false
end

local function next_window(context, current)
    if #context.windows == 0 then
        return nil
    end
    for index, window in ipairs(context.windows) do
        if window.id == current then
            return context.windows[index % #context.windows + 1].id
        end
    end
    return context.windows[1].id
end

local function manage(context)
    for _, event in ipairs(context.events) do
        if event.type == "window_interaction" then
            focused[event.seat] = event.window
        end
    end

    local commands = {}
    local output = context.outputs[1]
    if output and #context.windows > 0 then
        local area = output.non_exclusive_area or output
        local width = math.floor(area.width / #context.windows)
        for index, window in ipairs(context.windows) do
            local x = area.x + (index - 1) * width
            table.insert(commands, {
                "propose_dimensions",
                window = window.id,
                width = index == #context.windows and area.x + area.width - x or width,
                height = area.height,
            })
            table.insert(commands, {
                "set_tiled",
                window = window.id,
                edges = { top = true, bottom = true, left = true, right = true },
            })
            table.insert(commands, {
                "set_capabilities",
                window = window.id,
            })
        end
    end

    if output and context.layer_shell_version > 0 then
        table.insert(commands, { "set_layer_shell_default", output = output.id })
    end

    for _, seat in ipairs(context.seats) do
        if not contains_window(context, focused[seat.id]) then
            focused[seat.id] = next_window(context)
        end
        if focus_next[seat.id] then
            focused[seat.id] = next_window(context, focused[seat.id])
            focus_next[seat.id] = nil
        end
        if close_focused[seat.id] then
            if focused[seat.id] then
                table.insert(commands, { "close", window = focused[seat.id] })
            end
            close_focused[seat.id] = nil
        end
        if focused[seat.id] then
            table.insert(commands, {
                "focus_window",
                seat = seat.id,
                window = focused[seat.id],
            })
        else
            table.insert(commands, { "clear_focus", seat = seat.id })
        end
    end

    if exit_session then
        table.insert(commands, { "exit_session" })
        exit_session = false
    end
    return commands
end

local function render(context)
    local output = context.outputs[1]
    if not output or #context.windows == 0 then
        return {}
    end

    local commands = {}
    local area = output.non_exclusive_area or output
    local width = math.floor(area.width / #context.windows)
    for index, window in ipairs(context.windows) do
        local x = area.x + (index - 1) * width
        table.insert(commands, { "set_position", window = window.id, x = x, y = area.y })
        table.insert(commands, { "show", window = window.id })
        if index == 1 then
            table.insert(commands, { "place_bottom", window = window.id })
        else
            table.insert(commands, {
                "place_above",
                window = window.id,
                other = context.windows[index - 1].id,
            })
        end
    end
    return commands
end

return river.app({
    manager = river.window_manager({
        bindings = {
            ["Super+Return"] = function()
                assert(process.spawn({ argv = { "foot" } }))
            end,
            ["Super+j"] = function(seat)
                focus_next[seat] = true
            end,
            ["Super+q"] = function(seat)
                close_focused[seat] = true
            end,
            ["Super+Shift+e"] = function()
                exit_session = true
            end,
        },
        manage = manage,
        render = render,
    }),
})
