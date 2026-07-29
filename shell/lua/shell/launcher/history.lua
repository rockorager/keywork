local xdg = require("keywork.xdg")

local M = {}

local function state_dir()
    return xdg.state_home() .. "/keywork-shell"
end

local function history_path()
    return state_dir() .. "/history"
end

-- Activation counts by entry id: { ["app:firefox.desktop"] = 12, ... }
function M.load()
    local counts = {}
    local file = io.open(history_path(), "r")
    if not file then
        return counts
    end
    for raw_line in file:lines() do
        local line = tostring(raw_line)
        local count, id = string.match(line, "^(%d+)%s+(.+)$")
        if count and id then
            -- Pre-provider rows were bare desktop ids; adopt them into the
            -- apps namespace.
            if not id:find(":", 1, true) then
                id = "app:" .. id
            end
            counts[id] = tonumber(count)
        end
    end
    file:close()
    return counts
end

function M.bump(counts, id)
    counts[id] = (counts[id] or 0) + 1
    xdg.mkdir_all(state_dir())
    local file = io.open(history_path(), "w")
    if not file then
        return
    end
    for entry_id, count in pairs(counts) do
        file:write(string.format("%d %s\n", count, entry_id))
    end
    file:close()
end

return M
