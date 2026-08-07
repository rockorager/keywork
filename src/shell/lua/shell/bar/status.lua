local kw = require("keywork")
local dbus = require("keywork.dbus")
local log = require("keywork.log")
local loop = require("keywork.loop")
local service = require("keywork.service")
local clock = require("shell.clock")
local util = require("shell.bar.util")

local label = util.label
local status_pill = util.status_pill

local UPOWER = "org.freedesktop.UPower"
local UPOWER_DEVICE = "org.freedesktop.UPower.Device"
local DISPLAY_DEVICE = "/org/freedesktop/UPower/devices/DisplayDevice"

local function read_cpu_times()
    local file = io.open("/proc/stat", "r")
    if not file then
        return nil
    end
    local line = file:read("*l")
    file:close()
    if not line or not line:match("^cpu%s") then
        return nil
    end

    local fields = {}
    for value in line:gmatch("%d+") do
        fields[#fields + 1] = tonumber(value)
        if #fields == 8 then
            break
        end
    end
    if #fields < 4 then
        return nil
    end

    local total = 0.0
    for _, value in ipairs(fields) do
        total = total + value
    end
    return {
        total = total,
        idle = fields[4] + (fields[5] or 0),
    }
end

local function cpu_usage(previous, current)
    local total = current.total - previous.total
    local idle = current.idle - previous.idle
    if total <= 0 then
        return nil
    end
    return math.max(0, math.min(100, math.floor((total - idle) * 100 / total + 0.5)))
end

local cpu_service = service.define("shell.bar.cpu", function(self)
    local previous = read_cpu_times()
    local timer = loop.timer({ interval = 1.0 })
    for _ in timer:ticks() do
        local current = read_cpu_times()
        if current then
            if previous then
                local usage = cpu_usage(previous, current)
                if usage then
                    self:publish(usage)
                end
            end
            previous = current
        end
    end
end)

local Cpu = kw.component({
    hot_id = "Cpu",
    hot_version = 1,
    start = function(self)
        self.usage = cpu_service:use(self.scope)
    end,

    build = function(self)
        local usage = self.usage and self.usage() or nil
        local text = usage and tostring(usage) .. "%" or "--%"
        return status_pill("cpu", "gauge_20_regular", text, self.props.colors.foreground)
    end,
})

local function upower_state_name(state)
    if state == 1 then
        return "Charging"
    elseif state == 2 then
        return "Discharging"
    elseif state == 4 then
        return "Full"
    elseif state == 5 then
        return "Pending charge"
    elseif state == 6 then
        return "Pending discharge"
    end
    return "Unknown"
end

local function battery_status_from_values(palette, percentage, state, show_percent)
    if not percentage then
        return status_pill("battery", "battery-level-0", "", palette.muted)
    end
    local capacity = math.max(0, math.min(100, math.floor(percentage + 0.5)))
    local status = upower_state_name(state)
    local level = math.floor(capacity / 10) * 10
    if capacity > 0 and level == 0 then
        level = 10
    end
    if capacity >= 95 then
        level = 100
    end

    local name = "battery-level-" .. tostring(level)
    if status == "Charging" then
        if level == 100 then
            name = "battery-full-charging"
        else
            name = name .. "-charging"
        end
    elseif status == "Full" then
        name = "battery-level-100-plugged-in"
    end

    local color = capacity < 20 and palette.danger or palette.foreground
    local text = show_percent and tostring(capacity) .. "%" or nil
    return status_pill("battery", name, text, color)
end

local battery_service = service.define("shell.bar.battery", function(self)
    local ok, bus = pcall(function()
        return dbus.system()
    end)
    if not ok or not bus then
        log.warn("battery dbus unavailable")
        return
    end

    -- The observer resyncs on UPower restarts and reports unavailable while
    -- the daemon is down, so no manual GetAll/signal plumbing is needed.
    local obs = bus:observe({
        destination = UPOWER,
        path = DISPLAY_DEVICE,
        interface = UPOWER_DEVICE,
        timeout_ms = 1000,
    })
    for event in obs:changes() do
        if event.available then
            self:publish({
                percentage = event.props.Percentage,
                state = event.props.State,
            })
        else
            self:publish({})
        end
    end
end)

local Battery = kw.component({
    hot_id = "Battery",
    hot_version = 2,
    start = function(self)
        self.battery = battery_service:use(self.scope)
    end,

    build = function(self)
        local battery = self.battery and self.battery() or {}
        return battery_status_from_values(
            self.props.colors,
            battery.percentage,
            battery.state,
            self.props.show_percent ~= false
        )
    end,
})

local Clock = kw.component({
    hot_id = "BarClock",
    hot_version = 2,
    start = function(self)
        self.timestamp = clock.use(self.scope)
    end,

    build = function(self)
        local timestamp = self.timestamp and self.timestamp() or os.time()
        local text = self.props.format and os.date(self.props.format, timestamp) or clock.format_bar(timestamp)
        return kw.padding({ x = self.props.colors.space[1], child = label(text) })
    end,
})

return {
    Battery = Battery,
    Clock = Clock,
    Cpu = Cpu,
}
