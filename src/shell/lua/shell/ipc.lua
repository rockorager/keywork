local dbus = require("keywork.dbus")
local log = require("keywork.log")

local M = {}

M.name = "dev.rockorager.keywork"
M.path = "/dev/rockorager/keywork"
M.interface = "dev.rockorager.keywork"

-- Owns dev.rockorager.keywork on the session bus and exports the shell's
-- control interface so keybindings can reach the running instance:
--   keywork-shell launcher   (dbus-send under the hood)
--   keywork-shell lock
--   keywork-shell volume up
--   keywork-shell brightness down
-- Owning the name also makes the shell single-instance. Returns nil plus
-- "no-bus" when the session bus is unavailable, or nil plus "name-taken"
-- when another shell already owns the name.
function M.serve(handlers)
    local ok, bus = pcall(function()
        return dbus.session()
    end)
    if not ok or not bus then
        log.warn("shell ipc disabled: session dbus unavailable")
        return nil, "no-bus"
    end

    local name_ok, name = pcall(function()
        return bus:request_name(M.name, { do_not_queue = true })
    end)
    if not name_ok or not name then
        bus:close()
        return nil, "name-taken"
    end

    local exported = bus:export(M.path, {
        [M.interface] = {
            methods = {
                Lock = {
                    in_signature = "",
                    call = function()
                        handlers.lock()
                    end,
                },
                ToggleLauncher = {
                    in_signature = "",
                    call = function()
                        handlers.toggle_launcher()
                    end,
                },
                AdjustAudio = {
                    in_signature = "ss",
                    call = function(_, kind, action)
                        assert(handlers.adjust_audio(kind, action), "invalid audio OSD action")
                    end,
                },
                AdjustBrightness = {
                    in_signature = "s",
                    call = function(_, action)
                        assert(handlers.adjust_brightness(action), "invalid brightness OSD action")
                    end,
                },
                ConfigureBackground = {
                    in_signature = "s",
                    call = function(_, payload)
                        local configured, err = handlers.configure_background(payload)
                        assert(configured, err)
                    end,
                },
            },
        },
    })

    return {
        bus = bus,
        name = name,
        exported = exported,
    }
end

return M
