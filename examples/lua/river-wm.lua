-- This policy chooses tiling and focus-follows-interaction. Keywork only
-- translates the returned commands into legal River protocol transactions.
local river = require("keywork.river")
local process = require("keywork.process")

local focused = {}
local focus_next = {}
local close_focused = {}
local floating = {}
local toggle_floating = {}
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

    for _, window in ipairs(context.windows) do
        if window.app_id == "org.keywork.effects" then
            floating[window.id] = true
        end
    end
    for id in pairs(floating) do
        if not contains_window(context, id) then
            floating[id] = nil
        end
    end
    for _, seat in ipairs(context.seats) do
        if not contains_window(context, focused[seat.id]) then
            focused[seat.id] = next_window(context)
        end
        if toggle_floating[seat.id] then
            local window = focused[seat.id]
            if window then
                floating[window] = not floating[window]
            end
            toggle_floating[seat.id] = nil
        end
    end

    local commands = {}
    local output = context.outputs[1]
    if output and #context.windows > 0 then
        local area = output.non_exclusive_area or output
        local tiled_count = 0
        for _, window in ipairs(context.windows) do
            if not floating[window.id] then
                tiled_count = tiled_count + 1
            end
        end
        local tiled_index = 0
        for _, window in ipairs(context.windows) do
            local width
            local height
            if floating[window.id] then
                width = math.max(1, math.floor(area.width * 0.7))
                height = math.max(1, math.floor(area.height * 0.7))
            else
                tiled_index = tiled_index + 1
                width = math.floor(area.width / tiled_count)
                local x = area.x + (tiled_index - 1) * width
                if tiled_index == tiled_count then
                    width = area.x + area.width - x
                end
                height = area.height
            end
            table.insert(commands, {
                "propose_dimensions",
                window = window.id,
                width = width,
                height = height,
            })
            table.insert(commands, {
                "set_tiled",
                window = window.id,
                edges = floating[window.id] and {} or
                    { top = true, bottom = true, left = true, right = true },
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
    local tiled_count = 0
    for _, window in ipairs(context.windows) do
        if not floating[window.id] then
            tiled_count = tiled_count + 1
        end
    end
    local order = {}
    local tiled_index = 0
    for _, window in ipairs(context.windows) do
        if not floating[window.id] then
            tiled_index = tiled_index + 1
            local width = math.floor(area.width / tiled_count)
            local x = area.x + (tiled_index - 1) * width
            table.insert(commands, { "set_position", window = window.id, x = x, y = area.y })
            table.insert(commands, { "show", window = window.id })
            table.insert(order, window.id)
        end
    end
    local floating_index = 0
    for _, window in ipairs(context.windows) do
        if floating[window.id] then
            floating_index = floating_index + 1
            local width = math.max(1, math.floor(area.width * 0.7))
            local height = math.max(1, math.floor(area.height * 0.7))
            local offset = (floating_index - 1) * 32
            local x = area.x + math.floor((area.width - width) / 2) + offset
            local y = area.y + math.floor((area.height - height) / 2) + offset
            x = math.min(x, area.x + area.width - width)
            y = math.min(y, area.y + area.height - height)
            table.insert(commands, { "set_position", window = window.id, x = x, y = y })
            table.insert(commands, { "show", window = window.id })
            table.insert(order, window.id)
        end
    end
    for index, window in ipairs(order) do
        if index == 1 then
            table.insert(commands, { "place_bottom", window = window })
        else
            table.insert(commands, {
                "place_above",
                window = window,
                other = order[index - 1],
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
            ["Super+g"] = function()
                assert(process.spawn({ argv = { "ghostty" } }))
            end,
            ["Super+Shift+g"] = function()
                assert(process.spawn({
                    argv = {
                        "ghostty",
                        "--class=org.keywork.effects",
                    },
                }))
            end,
            ["Super+space"] = function(seat)
                toggle_floating[seat] = true
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
