-- A small, event-driven River input policy. Run this as a separate Keywork
-- process alongside examples/lua/river-wm.lua.

local river = require("keywork.river")

local function find_device(context, id)
    for _, device in ipairs(context.devices) do
        if device.id == id then
            return device
        end
    end
end

local function update(context)
    local commands = {}

    for _, event in ipairs(context.events) do
        if event.type == "device_added" then
            local device = find_device(context, event.device)
            if device and device.type == "keyboard" then
                table.insert(commands, {
                    "set_repeat_info",
                    device = device.id,
                    rate = 25,
                    delay = 600,
                })
            end

            local tap = device and device.libinput and device.libinput.tap
            if tap and tap.support and tap.support > 0 then
                table.insert(commands, {
                    "set_tap",
                    device = device.id,
                    state = "enabled",
                })
            end
        elseif event.type == "libinput_result" and event.status ~= "success" then
            print(
                string.format(
                    "River rejected %s for device %s: %s",
                    event.operation,
                    event.device or event.accel_config,
                    event.status
                )
            )
        end
    end

    return commands
end

return river.input_app({
    update = update,
})
