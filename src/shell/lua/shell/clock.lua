local loop = require("keywork.loop")
local service = require("keywork.service")

local M = {}

local function seconds_until_next_minute()
    ---@type { sec: integer }
    local now = os.date("*t") --[[@as { sec: integer }]]
    return 60 - now.sec
end

local clock_service = service.define("shell.clock", function(self)
    self:publish(os.time())
    local timer = loop.timer({ delay = seconds_until_next_minute(), interval = 60.0 })
    for _ in timer:ticks() do
        self:publish(os.time())
    end
end)

function M.use(scope, on_change)
    return clock_service:use(scope, on_change)
end

function M.format_bar(timestamp)
    return os.date("%a %b %d  %I:%M %p", timestamp)
end

function M.format_time(timestamp)
    return (os.date("%I:%M", timestamp):gsub("^0", ""))
end

function M.format_date(timestamp)
    local date = os.date("%A, %B", timestamp)
    local day = tonumber(os.date("%d", timestamp))
    return string.format("%s %d", date, day)
end

return M
