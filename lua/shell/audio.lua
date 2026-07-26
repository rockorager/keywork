local kw = require("keywork")
local keywork_audio = require("keywork.audio")
local log = require("keywork.log")
local service = require("keywork.service")
local bar_colors = require("shell.bar.colors")
local util = require("shell.bar.util")

local status_pill = util.status_pill

local M = {}

M.settings_width = 520
M.settings_height = 540

---@type keywork.audio.Monitor?
local active_monitor = nil

local audio_service = service.define("shell.audio", function(self)
    local monitor, err = keywork_audio.monitor()
    if not monitor then
        log.warn("PipeWire audio unavailable", err or "unknown")
        self:publish({ outputs = {}, inputs = {} })
        return
    end
    active_monitor = monitor
    self.scope:on_cancel(function()
        if active_monitor == monitor then active_monitor = nil end
        monitor:close()
    end)

    local function publish()
        self:publish({
            output = monitor:default_sink(),
            input = monitor:default_source(),
            outputs = monitor:sinks(),
            inputs = monitor:sources(),
        })
    end

    publish()
    for _ in monitor:events() do
        publish()
    end
end)

function M.use(scope, on_change)
    return audio_service:use(scope, on_change)
end

local device_kind = {
    volume = "sink",
    microphone = "source",
}

function M.adjust(kind, action, count)
    local monitor = active_monitor
    local target_kind = device_kind[kind]
    if not monitor then return nil, "PipeWire audio unavailable" end
    if not target_kind then return nil, "invalid audio kind" end
    local device = monitor:default(target_kind)
    if not device then return nil, "default audio device unavailable" end

    count = math.max(1, math.floor(tonumber(count) or 1))
    local ok, err
    if action == "mute" then
        if count % 2 == 1 then ok, err = monitor:toggle_muted(device.id) end
    elseif action == "up" or action == "down" then
        if device.muted then
            ok, err = monitor:set_muted(device.id, false)
            if not ok then return nil, err end
        end
        local direction = action == "up" and 1 or -1
        ok, err = monitor:adjust_volume(device.id, direction * count * 0.05, 1.0)
    else
        return nil, "invalid audio action"
    end
    if not ok and err then return nil, err end
    return monitor:default(target_kind)
end

function M.set_default(device)
    local monitor = active_monitor
    if not monitor then return nil, "PipeWire audio unavailable" end
    return monitor:set_default(device.kind, device.name)
end

local function menu_label(value, color)
    return kw.text(value, {
        color = color,
        max_lines = 1,
    })
end

local function volume_icon(kind, device)
    local prefix = kind == "microphone" and "microphone-sensitivity" or "audio-volume"
    local volume = device and device.volume or 0
    if not device or device.muted or volume <= 0 then
        return prefix .. "-muted"
    elseif volume < 0.34 then
        return prefix .. "-low"
    elseif volume < 0.67 then
        return prefix .. "-medium"
    end
    return prefix .. "-high"
end

local function volume_status(palette, device, on_activate)
    local color = palette.foreground
    if not device or device.muted or (device.volume or 0) <= 0 then
        color = palette.muted
    end
    return status_pill("volume", volume_icon("volume", device), nil, color, {
        on_activate = on_activate,
    })
end

local function device_icon(kind, device)
    local generic = kind == "sink" and "audio-volume-high" or "audio-input-microphone"
    local name = device.icon_name
    if not name or name == "" or name:match("^audio%-card") or name == "audio-speakers" then
        return generic
    end
    if name == "audio-headphones-bluetooth" then
        return "audio-headphones"
    end
    return name
end

local function device_label(kind, device, detailed)
    local internal = device.bus == "pci" or device.bus == "platform"
    local nick = device.nick
    if internal then
        if kind == "sink" and device.port_type == "speaker" then
            return "Built-in Speakers"
        elseif kind == "source" and device.port_type == "mic" then
            return "Built-in Microphone"
        end
    end
    if detailed and device.description and device.description ~= "" then
        if nick and nick ~= "" and device.description:sub(1, #nick + 1) == nick .. " " then
            return nick .. " · " .. device.description:sub(#nick + 2)
        end
        return device.description
    end
    if nick and nick ~= "" then
        return nick
    end
    return device.description or device.name
end

local function device_row(palette, kind, device, on_select)
    local color = not device.default and palette.muted or nil
    return kw.menu_item({
        id = "audio-" .. kind .. "-" .. tostring(device.id),
        on_activate = on_select
            and function()
                on_select(device)
            end or nil,
        child = kw.row({
            spacing = palette.space[2],
            align = "center",
            children = {
                kw.icon({
                    name = device_icon(kind, device),
                    color = palette.muted,
                }),
                kw.expanded({ child = menu_label(device_label(kind, device, true), color) }),
                device.default
                    and kw.icon({
                        name = "object-select",
                        color = palette.foreground,
                    })
                    or kw.sized_box({ width = palette.space[4], child = kw.text("") }),
            },
        }),
    })
end

local function unavailable_row(palette, label)
    return kw.padding({
        x = palette.space[3],
        y = palette.space[2],
        child = menu_label(label, palette.subtle),
    })
end

local function device_rows(palette, kind, devices, on_select)
    local rows = {}
    for _, device in ipairs(devices) do
        if device.available ~= false then
            rows[#rows + 1] = device_row(palette, kind, device, on_select)
        end
    end
    if #rows == 0 then
        rows[1] = unavailable_row(palette, "No available devices")
    end
    return rows
end

local function default_device_row(palette, kind, device)
    if not device then
        local label = kind == "sink" and "No default output" or "No default input"
        return unavailable_row(palette, label)
    end
    return device_row(palette, kind, device)
end

local function audio_menu(palette, audio, on_select, on_open_settings)
    audio = audio or {}
    local rows = { kw.menu_label({ text = "Output" }) }
    for _, row in ipairs(device_rows(palette, "sink", audio.outputs or {}, on_select)) do
        rows[#rows + 1] = row
    end
    rows[#rows + 1] = kw.menu_label({ text = "Input" })
    rows[#rows + 1] = default_device_row(palette, "source", audio.input)
    rows[#rows + 1] = kw.menu_separator({})
    rows[#rows + 1] = kw.menu_item({
        id = "audio-settings",
        on_activate = on_open_settings,
        child = kw.row({
            spacing = palette.space[2],
            align = "center",
            children = {
                kw.icon({ name = "preferences-system-symbolic", color = palette.muted }),
                kw.expanded({ child = menu_label("Advanced audio settings…", palette.muted) }),
                kw.icon({ name = "pan-end-symbolic", color = palette.muted }),
            },
        }),
    })
    return kw.menu_surface({
        child = kw.column({ children = rows }),
    })
end

local function settings_menu(palette, audio, on_select)
    audio = audio or { outputs = {}, inputs = {} }
    on_select = on_select or function(_) end
    local rows = { kw.menu_label({ text = "Output" }) }
    for _, row in ipairs(device_rows(palette, "sink", audio.outputs or {}, on_select)) do
        rows[#rows + 1] = row
    end
    rows[#rows + 1] = kw.menu_label({ text = "Input" })
    for _, row in ipairs(device_rows(palette, "source", audio.inputs or {}, on_select)) do
        rows[#rows + 1] = row
    end
    return kw.menu_surface({
        child = kw.column({ children = rows }),
    })
end

local AudioMenu = kw.stateful({
    build = function(self)
        return audio_menu(
            self.props.colors,
            self.props.audio,
            self.props.on_select,
            self.props.on_open_settings
        )
    end,
})

local Audio = kw.stateful({
    init = function(self)
        self.audio_tap = function()
            self:set_state(function(state)
                state.menu_open = not state.menu_open
            end)
        end
        self.audio = M.use(self.scope, function(snapshot)
            self.audio = snapshot
            self:set_state()
        end)
    end,

    open_settings = function(self)
        self:set_state(function(state)
            state.menu_open = false
        end)
        if self.props.on_open_settings then self.props.on_open_settings() end
    end,

    select_device = function(_, device)
        local ok, err = M.set_default(device)
        if not ok then log.warn("audio default selection failed", err or "unknown") end
    end,

    build = function(self)
        local palette = self.props.colors
        local audio = self.audio or {}
        return kw.popover({
            id = "audio",
            anchor = volume_status(palette, audio.output, self.audio_tap),
            open = self.menu_open,
            placement = { edge = "bottom", alignment = "end", gap = palette.space[1] },
            width = 420,
            content = function()
                        return audio_menu(
                            palette, self.audio,
                            function(device)
                                self:select_device(device)
                            end,
                            function()
                                self:open_settings()
                            end
                        )
                    end,
            on_close = function()
                        self:set_state(function(state)
                            state.menu_open = false
                        end)
                    end,
        })
    end,
})

local Settings = kw.stateful({
    init = function(self)
        if not self.props.audio then
            self.audio = M.use(self.scope, function(snapshot)
                self.audio = snapshot
                self:set_state()
            end)
        end
    end,

    select_device = function(self, device)
        if self.props.on_select then
            self.props.on_select(device)
            return
        end
        local ok, err = M.set_default(device)
        if not ok then log.warn("audio default selection failed", err or "unknown") end
    end,

    build = function(self, context)
        local theme = context.theme
        local palette = self.props.colors or bar_colors.palette(theme)
        local audio = self.props.audio or self.audio or {}
        local content = kw.sized_box({
            width = M.settings_width,
            height = M.settings_height,
            child = kw.container({
                background = palette.background,
                radius = theme.radius[3],
                padding = { all = palette.space[4] },
                child = kw.column({
                    spacing = palette.space[4],
                    children = {
                        kw.row({
                            spacing = palette.space[3],
                            align = "center",
                            children = {
                                kw.icon({
                                    name = "audio-card-symbolic",
                                    color = palette.foreground,
                                    size = theme.font_size[5],
                                }),
                                kw.expanded({ child =
                                    kw.column({
                                        spacing = palette.space[1],
                                        children = {
                                            kw.text("Audio settings", { role = "title", max_lines = 1 }),
                                            kw.text("Choose the default routes used by new applications.", {
                                                color = palette.muted,
                                                max_lines = 1,
                                            }),
                                        },
                                    })
                                }),
                            },
                        }),
                        kw.expanded({ child =
                            kw.scroll_view({
                                id = "audio-settings-routes",
                                child = settings_menu(palette, audio, function(device)
                                    self:select_device(device)
                                end),
                            })
                        }),
                    },
                }),
            }),
        })

        return kw.theme({
            data = palette.theme,
            child = kw.actions({
                bindings = {
                    dismiss = function()
                        if self.props.on_close then self.props.on_close() end
                    end,
                },
                child = kw.shortcuts({
                    bindings = { escape = "dismiss" },
                    child = content,
                }),
            }),
        })
    end,
})

M.Audio = Audio
M.Menu = AudioMenu
M.Settings = Settings

return M
