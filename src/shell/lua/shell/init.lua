local kw = require("keywork")

local background = require("background")
local audio = require("shell.audio")
local bar = require("shell.bar")
local idle = require("shell.idle")
local ipc = require("shell.ipc")
local launcher = require("shell.launcher")
local notifications = require("shell.notifications")
local osd = require("shell.osd")
local session = require("shell.session")

---@class shell.Options
---@field bar? shell.BarOptions

local M = { bar = bar }

local function validate(options)
    if options == nil then
        options = {}
    end
    assert(type(options) == "table", "shell options must be a table")
    for key in pairs(options) do
        if key ~= "bar" then
            error("unknown shell option: " .. tostring(key), 3)
        end
    end
    return options
end

---@param options? shell.Options
---@return keywork.App
function M.app(options)
    options = validate(options)
    local bar_config = bar.configure(options.bar)

    -- Window-defining state survives reload and is tracked by windows().
    local shell_state = kw.app.hot.signal(
        "shell.root",
        {
            audio_settings_open = false,
            launcher_open = false,
        },
        {
            version = 2,
            migrate = function(previous)
                return previous or { audio_settings_open = false, launcher_open = false }
            end,
        }
    )

    local function set_audio_settings_open(open)
        if shell_state().audio_settings_open == open then
            return
        end
        shell_state:mutate(function(state)
            state.audio_settings_open = open
        end)
    end

    local function set_launcher_open(open)
        if shell_state().launcher_open == open then
            return
        end
        shell_state:mutate(function(state)
            state.launcher_open = open
        end)
    end

    ---@type OsdController?
    local osd_controller = nil
    ---@type SessionController?
    local session_controller = nil
    ---@type IdleController?
    local idle_controller = nil
    ---@type ShellIpcHandle?
    local ipc_handle = nil
    ---@type NotificationServer?
    local notification_server = nil

    local function stop()
        if ipc_handle then ipc_handle:close() end
        if notification_server then notification_server:close() end
        if osd_controller then osd_controller:close() end
        if idle_controller then idle_controller:stop() end
        if session_controller then session_controller:stop() end
        ipc_handle, notification_server, osd_controller = nil, nil, nil
        idle_controller, session_controller = nil, nil
    end

    local function start()
        stop()
        osd_controller = osd.new()
        session_controller = session.start()
        idle_controller = idle.start({
            lock = function()
                session_controller:lock()
            end,
        })
        local ipc_err
        ipc_handle, ipc_err = ipc.serve({
            toggle_launcher = function()
                set_launcher_open(not shell_state().launcher_open)
            end,
            lock = function()
                session_controller:lock()
            end,
            adjust_audio = function(kind, action)
                return osd_controller:adjust_audio(kind, action)
            end,
            adjust_brightness = function(action)
                return osd_controller:adjust_brightness(action)
            end,
            configure_background = function(payload)
                return background.configure(payload)
            end,
        })
        if not ipc_handle and ipc_err == "name-taken" then
            io.stderr:write("keywork-shell: another instance already owns " .. ipc.name .. "\n")
            os.exit(1)
        end
        notification_server = notifications.serve()
    end

    ---@type shell.BarActions
    local bar_actions = {
        open_audio_settings = function()
            set_audio_settings_open(true)
        end,
        toggle_launcher = function()
            set_launcher_open(not shell_state().launcher_open)
        end,
    }

    return kw.app({
        app_id = "dev.rockorager.keywork.Shell",
        backend = "wayring",
        start = start,
        stop = stop,
        windows = function(ctx)
            local state = shell_state()
            local windows = {}
            local has_output = ctx.outputs[1] ~= nil
            background.append_windows(windows, ctx.outputs)
            for index, output in ipairs(ctx.outputs) do
                windows[#windows + 1] = kw.window({
                    id = "bar:" .. output.name,
                    output = output.name,
                    width = 0, -- stretch to the anchored edges
                    height = bar_config.height,
                    layer_shell = {
                        layer = "top",
                        anchor = { "top", "left", "right" },
                        exclusive_zone = bar_config.height,
                    },
                    child = bar.Bar({
                        key = "bar",
                        output = output.name,
                        output_index = index,
                        config = bar_config,
                        actions = bar_actions,
                    }),
                })
            end

            if state.audio_settings_open then
                windows[#windows + 1] = kw.window({
                    id = "audio-settings",
                    title = "Audio Settings",
                    width = audio.settings_width,
                    height = audio.settings_height,
                    on_close = function()
                        set_audio_settings_open(false)
                    end,
                    child = audio.Settings({
                        key = "audio-settings",
                        on_close = function()
                            set_audio_settings_open(false)
                        end,
                    }),
                })
            end

            -- The launcher window's existence follows app state: declaring it
            -- creates the surface, dropping it destroys it. No output asks the
            -- compositor to use the output under the pointer; no anchors centers it.
            if state.launcher_open and has_output then
                windows[#windows + 1] = kw.window({
                    id = "launcher",
                    width = launcher.width,
                    height = launcher.height,
                    layer_shell = {
                        layer = "overlay",
                        keyboard = "exclusive",
                    },
                    child = launcher.Launcher({
                        key = "launcher",
                        on_dismiss = function()
                            set_launcher_open(false)
                        end,
                    }),
                })
            end

            local level = osd_controller and osd_controller:visible()
            if level and has_output then
                windows[#windows + 1] = kw.window({
                    id = "osd",
                    width = osd.width,
                    height = osd.height,
                    layer_shell = {
                        layer = "overlay",
                        anchor = { "bottom" },
                        margin = { bottom = osd.margin },
                    },
                    child = osd.Level({
                        key = "osd-level",
                        level = level,
                    }),
                })
            end

            local visible_notifications = notification_server and notification_server.notifications() or {}
            if has_output and #visible_notifications > 0 then
                -- Match Fluent's default corner-toaster offsets.
                windows[#windows + 1] = kw.window({
                    id = "notifications",
                    width = notifications.width,
                    height = "content",
                    layer_shell = {
                        layer = "overlay",
                        anchor = { "top", "right" },
                        margin = {
                            top = notifications.vertical_offset,
                            right = notifications.horizontal_offset,
                        },
                    },
                    child = notifications.Stack({
                        key = "notification-stack",
                        server = notification_server,
                    }),
                })
            end

            return windows
        end,
    })
end

return M
