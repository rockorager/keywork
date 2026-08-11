local kw = require("keywork")
local dbus = require("keywork.dbus")
local fs = require("keywork.fs")
local log = require("keywork.log")
local loop = require("keywork.loop")
local audio = require("shell.audio")

local M = {}

M.width = 208
M.height = 48
M.margin = 96

local TRACK_WIDTH = 144
local DISPLAY_MS = 1400

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function icon_for(kind, value, muted)
    if kind == "brightness" then
        return "display-brightness-symbolic"
    end
    local prefix = kind == "microphone" and "microphone-sensitivity" or "audio-volume"
    if muted or value <= 0 then
        return prefix .. "-muted"
    elseif value < 0.34 then
        return prefix .. "-low"
    elseif value < 0.67 then
        return prefix .. "-medium"
    end
    return prefix .. "-high"
end

local function level_bar(theme, value, muted)
    local fill_width = math.floor(TRACK_WIDTH * (muted and 0 or clamp(value, 0, 1)) + 0.5)
    local track_height = theme.space[1]
    local fill = kw.sized_box({
        width = fill_width,
        height = track_height,
        child = kw.container({
            background = theme.colors.accent,
            radius = theme.radius[6],
            min_width = fill_width,
            min_height = track_height,
            child = kw.text(""),
        }),
    })
    return kw.sized_box({
        width = TRACK_WIDTH,
        height = track_height,
        child = kw.container({
            background = theme.colors.fill_secondary,
            radius = theme.radius[6],
            min_width = TRACK_WIDTH,
            min_height = track_height,
            horizontal_align = "start",
            vertical_align = "center",
            child = fill,
        }),
    })
end

local Level = kw.component({
    hot_id = "Level",
    hot_version = 3,

    build = function(self, context)
        local theme = context.theme
        local level = self.props.level
        local value = clamp(tonumber(level.value) or 0, 0, 1)
        local muted = level.muted == true

        return kw.container({
            background = theme.colors.surface,
            border = theme.colors.panel_border,
            border_width = 1,
            radius = theme.radius[5],
            shadow = theme.shadow[5],
            min_width = M.width,
            min_height = M.height,
            padding = { x = theme.space[3] },
            vertical_align = "center",
            child = kw.row({
                align = "center",
                spacing = theme.space[3],
                children = {
                    kw.icon({
                        name = icon_for(level.kind, value, muted),
                        size = theme.space[5],
                        color = muted and theme.colors.text_tertiary or theme.colors.text,
                    }),
                    level_bar(theme, value, muted),
                },
            }),
        })
    end,
})

M.Level = Level

local Controller = {}
Controller.__index = Controller

---@class OsdController
---@field current           keywork.Signal<table?>
---@field hide_timer?       keywork.loop.Timer
---@field running           boolean
---@field backlight_name?   string
---@field system_bus?       keywork.dbus.Bus
---@field closed            boolean
---@field close             fun(self: OsdController)
---@field visible           fun(self: OsdController): table?
---@field adjust_audio      fun(self: OsdController, kind: string, action: string): boolean
---@field adjust_brightness fun(self: OsdController, action: string): boolean

function Controller:visible()
    return self.current()
end

function Controller:close()
    ---@diagnostic disable-next-line: unnecessary-if
    if self.closed then return end
    self.closed = true
    ---@diagnostic disable-next-line: unnecessary-if
    if self.hide_timer then self.hide_timer:cancel() end
    ---@diagnostic disable-next-line: unnecessary-if
    if self.system_bus then self.system_bus:close() end
    self.hide_timer, self.system_bus = nil, nil
    self.jobs = {}
    self.running = false
end

function Controller:show(kind, value, muted)
    self.current:set({
        kind = kind,
        value = clamp(value, 0, 1),
        muted = muted == true,
    })

    local previous = self.hide_timer
    local timer = loop.timer({ delay = DISPLAY_MS / 1000 })
    self.hide_timer = timer
    -- EmmyLua 0.24 retains the post-assignment type for the pre-assignment local.
    ---@diagnostic disable-next-line: unnecessary-if
    if previous then
        previous:cancel()
    end
    loop.spawn(function()
        for _ in timer:ticks() do
            if self.hide_timer == timer then
                self.hide_timer = nil
                self.current:set(nil)
            end
        end
    end)
end

function Controller:enqueue(key, action, run_job)
    local pending = self.jobs[#self.jobs]
    if pending and pending.key == key and pending.action == action then
        pending.count = pending.count + 1
        return
    end
    self.jobs[#self.jobs + 1] = {
        key = key,
        action = action,
        count = 1,
        run = run_job,
    }
    -- EmmyLua 0.24 narrows mutable instance fields from their initializer.
    ---@diagnostic disable-next-line: unnecessary-if
    if self.running then
        return
    end
    self.running = true
    loop.spawn(function()
        while #self.jobs > 0 do
            local job = self.jobs[1]
            local count = job.count
            job.count = 0
            job.run(count)
            -- Repeats received while the job yielded merge back into this job;
            -- process them as one batch instead of replaying stale intermediate
            -- levels after the key is released.
            if job.count == 0 then
                table.remove(self.jobs, 1)
            end
        end
        self.running = false
    end)
end

function Controller:adjust_audio(kind, action)
    if (kind ~= "volume" and kind ~= "microphone") or (action ~= "up" and action ~= "down" and action ~= "mute") then
        return false
    end
    self:enqueue("audio:" .. kind, action, function(count)
        local state, err = audio.adjust(kind, action, count)
        if not state then
            log.warn("audio control failed", err or "unknown")
            return
        end
        self:show(kind, state.volume or 0, state.muted)
    end)
    return true
end

local function read_number(path)
    local value = fs.read(path)
    return value and tonumber(value:match("^%s*(%d+)")) or nil
end

function Controller.read_backlight(root, name)
    local value = read_number(root .. "/brightness")
    local maximum = read_number(root .. "/max_brightness")
    if not value or not maximum or maximum <= 0 then
        return nil
    end
    return {
        name = name or root:match("([^/]+)$"),
        value = value,
        maximum = maximum,
    }
end

function Controller:backlight()
    local preferred = os.getenv("KEYWORK_BACKLIGHT_DEVICE")
    if preferred and preferred ~= "" then
        return self.read_backlight("/sys/class/backlight/" .. preferred, preferred)
    end
    -- EmmyLua 0.24 narrows mutable instance fields from their initializer.
    ---@diagnostic disable-next-line: unnecessary-if
    if self.backlight_name then
        local current = self.read_backlight("/sys/class/backlight/" .. self.backlight_name, self.backlight_name)
        if current then
            return current
        end
        self.backlight_name = nil
    end
    local entries, err = fs.list("/sys/class/backlight")
    if not entries then
        log.warn("backlight discovery failed", err or "unknown")
        return nil
    end
    table.sort(entries, function(left, right)
        return left.name < right.name
    end)
    for _, entry in ipairs(entries) do
        local current = self.read_backlight("/sys/class/backlight/" .. entry.name, entry.name)
        if current then
            self.backlight_name = entry.name
            return current
        end
    end
    log.warn("brightness osd disabled: no backlight device")
    return nil
end

function Controller:system()
    -- EmmyLua 0.24 narrows mutable instance fields from their initializer.
    ---@diagnostic disable-next-line: unnecessary-if
    if self.system_bus then
        return self.system_bus
    end
    local ok, bus = pcall(function()
        return dbus.system()
    end)
    if not ok or not bus then
        log.warn("brightness control failed: system dbus unavailable")
        return nil
    end
    self.system_bus = bus
    return bus
end

function Controller:adjust_brightness(action)
    if action ~= "up" and action ~= "down" then
        return false
    end
    self:enqueue("brightness", action, function(count)
        local current = self:backlight()
        if not current then
            return
        end
        local step = math.max(1, math.floor(current.maximum * 0.05 + 0.5))
        local delta = count * step * (action == "up" and 1 or -1)
        local target = clamp(current.value + delta, 0, current.maximum)
        if target ~= current.value then
            local bus = self:system()
            if not bus then
                return
            end
            local reply, err = bus:call({
                destination = "org.freedesktop.login1",
                path = "/org/freedesktop/login1/session/auto",
                interface = "org.freedesktop.login1.Session",
                member = "SetBrightness",
                args = {
                    dbus.string("backlight"),
                    dbus.string(current.name),
                    dbus.uint32(math.floor(target)),
                },
                timeout_ms = 1000,
            })
            if not reply then
                log.warn("brightness control failed", err or "unknown")
                return
            end
        end
        self:show("brightness", target / current.maximum, false)
    end)
    return true
end

function M.new()
    ---@type OsdController
    local controller = setmetatable({
        current = kw.signal(nil),
        jobs = {},
        running = false,
        closed = false,
    }, Controller)
    return controller
end

return M
