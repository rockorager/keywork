local kw = require("keywork")
local dbus = require("keywork.dbus")
local log = require("keywork.log")
local service = require("keywork.service")
local clock = require("shell.clock")
local util = require("shell.bar.util")

local label = util.label
local status_pill = util.status_pill

local UPOWER = "org.freedesktop.UPower"
local UPOWER_DEVICE = "org.freedesktop.UPower.Device"
local DISPLAY_DEVICE = "/org/freedesktop/UPower/devices/DisplayDevice"

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

local Battery = kw.stateful({
    hot_id = "Battery",
    hot_version = 1,
    start = function(self)
        self.battery = battery_service:use(self.scope, function(battery)
            self.battery = battery
            self:set_state()
        end)
    end,

    build = function(self)
        local battery = self.battery or {}
        return battery_status_from_values(
            self.props.colors,
            battery.percentage,
            battery.state,
            self.props.show_percent ~= false
        )
    end,
})

local Clock = kw.stateful({
    hot_id = "BarClock",
    hot_version = 1,
    start = function(self)
        self.timestamp = clock.use(self.scope, function(timestamp)
            self.timestamp = timestamp
            self:set_state()
        end)
    end,

    build = function(self)
        local timestamp = self.timestamp or os.time()
        local text = self.props.format and os.date(self.props.format, timestamp) or clock.format_bar(timestamp)
        return kw.padding({ x = self.props.colors.space[1], child = label(text) })
    end,
})

return {
    Battery = Battery,
    Clock = Clock,
}
