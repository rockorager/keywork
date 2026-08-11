local xdg = require("keywork.xdg")
local fs = require("keywork.fs")

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
    local data = fs.read(history_path())
    if not data then
        return counts
    end
    for raw_line in data:gmatch("[^\n]+") do
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
    return counts
end

function M.bump(counts, id)
    counts[id] = (counts[id] or 0) + 1
    fs.mkdir(state_dir(), { parents = true })
    local lines = {}
    for entry_id, count in pairs(counts) do
        table.insert(lines, string.format("%d %s\n", count, entry_id))
    end
    fs.write(history_path(), table.concat(lines))
end

return M
