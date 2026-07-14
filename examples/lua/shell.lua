local kw = require("keywork")
local loop = require("keywork.loop")

-- Seed of the keywork-shell example: a bar that grows into a full
-- desktop shell (bar + menus + launcher).
--
--   [windows]  the app's windows(ctx) function returns kw.window nodes
--              keyed by id, one bar per output; outputs hotplug just
--              rebuilds the window set
--   [popups]   the clock opens a menu via kw.anchored/kw.popup
--   [launcher] a launcher window toggled by state, not a process:
--              the bar button flips shell.launcher_open and the
--              window's existence follows it; Escape flips it back
--
-- Run with:
--   zig build run-lua-shell-example
-- or:
--   zig build run -- examples/lua/shell.lua

local colors = {
    background = 0xf0111113,
    text = 0xffedeef0,
    muted = 0xff797b86,
    accent = 0xff0090ff,
}

-- App-level state shared by the window set and every window's widgets.
-- Widget state (kw.stateful) is per-runtime, so anything that decides
-- which windows exist lives here and flips via kw.app.invalidate().
local shell = {
    launcher_open = false,
}

local function set_launcher_open(open)
    shell.launcher_open = open
    kw.app.invalidate()
end

local function seconds_until_next_minute()
    local now = os.date("*t")
    return 60 - now.sec
end

local Clock = kw.stateful({
    init = function(self)
        self:update_time()
        self.timer = loop.timer({ delay = seconds_until_next_minute(), interval = 60.0 })
        local timer = self.timer
        loop.spawn(function()
            for _ in timer:ticks() do
                self:set_state(function(state)
                    state:update_time()
                end)
            end
        end)
    end,

    dispose = function(self)
        if self.timer then
            self.timer:cancel()
        end
    end,

    update_time = function(self)
        self.time = os.date("%a %b %d  %I:%M %p")
    end,

    build_menu = function(self)
        local function item(label)
            return kw.gesture({
                id = "menu-" .. label,
                hover_background = 0xff2a2c31,
                on_tap = function()
                    self:set_state(function(state)
                        state.menu_open = false
                    end)
                end,
                child = kw.padding({
                    x = 12,
                    y = 6,
                    child = kw.text(label, { color = colors.text }),
                }),
            })
        end
        return kw.container({
            background = colors.background,
            radius = 6,
            padding = 4,
            child = kw.column({
                children = {
                    kw.padding({
                        x = 12,
                        y = 6,
                        child = kw.text(os.date("%A, %B %d %Y"), { color = colors.muted }),
                    }),
                    item("Calendar"),
                    item("Clock settings"),
                },
            }),
        })
    end,

    build = function(self)
        -- [popups] Clicking the clock toggles menu_open; the popup's
        -- existence follows that state, so the compositor dismissing it
        -- (on_close) and tapping an item both just clear the flag.
        return kw.anchored({
            id = "clock",
            popup = self.menu_open
                and kw.popup({
                    edge = "bottom",
                    alignment = "end",
                    gap = 4,
                    content = function()
                        return self:build_menu()
                    end,
                    on_close = function()
                        self:set_state(function(state)
                            state.menu_open = false
                        end)
                    end,
                }) or nil,
            child = kw.gesture({
                id = "clock-tap",
                on_tap = function()
                    self:set_state(function(state)
                        state.menu_open = not state.menu_open
                    end)
                end,
                child = kw.text(self.time, {
                    color = self.menu_open and colors.accent or colors.text,
                }),
            }),
        })
    end,
})

local Bar = kw.stateful({
    build = function(self, state)
        return kw.container({
            background = colors.background,
            padding = { left = 12, right = 12, top = 4, bottom = 4 },
            child = kw.row({
                spacing = 12,
                align = "center",
                children = {
                    -- [launcher] the toggle lives in app state, not widget state,
          -- because it decides whether a *window* exists.
                    kw.gesture({
                        id = "launcher-toggle",
                        hover_background = 0xff2a2c31,
                        on_tap = function()
                            set_launcher_open(not shell.launcher_open)
                        end,
                        child = kw.text("keywork", {
                            color = shell.launcher_open and colors.accent or colors.muted,
                        }),
                    }),
                    kw.spacer(),
                    Clock({ key = "clock" }),
                },
            }),
        })
    end,
})

-- [launcher] The launcher is just another window whose surface grabs
-- the keyboard (layer_shell.keyboard = "exclusive") so the Escape
-- shortcut reaches it without any widget being focused.
local function launcher_view()
    local function item(label)
        return kw.gesture({
            id = "launch-" .. label,
            hover_background = 0xff2a2c31,
            on_tap = function()
                set_launcher_open(false)
            end,
            child = kw.container({
                padding = { left = 12, right = 12, top = 8, bottom = 8 },
                child = kw.text(label, { color = colors.text }),
            }),
        })
    end

    return kw.actions({
        bindings = {
            ["close-launcher"] = function()
                set_launcher_open(false)
            end,
        },
        child = kw.shortcuts({
            bindings = { escape = "close-launcher" },
            child = kw.container({
                background = colors.background,
                radius = 12,
                padding = { left = 8, right = 8, top = 8, bottom = 8 },
                child = kw.column({
                    children = {
                        kw.container({
                            padding = { left = 12, right = 12, top = 8, bottom = 8 },
                            child = kw.text("Launcher — Escape closes", { color = colors.muted }),
                        }),
                        item("Terminal"),
                        item("Browser"),
                        item("Files"),
                    },
                }),
            }),
        }),
    })
end

-- [windows] One bar per output, each its own window with its own
-- runtime and popups. Plugging or unplugging a monitor re-runs this
-- function and the window set is diffed by id.
return kw.app({
    app_id = "dev.keywork.Shell",
    backend = "cpu",
    windows = function(ctx)
        local windows = {}
        for _, output in ipairs(ctx.outputs) do
            windows[#windows + 1] = kw.window({
                id = "bar:" .. output.name,
                output = output.name,
                width = 0, -- stretch to the anchored edges
                height = 32,
                layer_shell = {
                    layer = "top",
                    anchor = { "top", "left", "right" },
                    exclusive_zone = 32,
                },
                child = Bar({ key = "bar" }),
            })
        end
        -- [launcher] the window's existence follows app state: declaring it
        -- creates the surface, dropping it destroys it. No anchors, so the
        -- compositor centers it on the output.
        if shell.launcher_open and ctx.outputs[1] then
            windows[#windows + 1] = kw.window({
                id = "launcher",
                output = ctx.outputs[1].name,
                width = 420,
                height = 240,
                layer_shell = {
                    layer = "overlay",
                    keyboard = "exclusive",
                },
                child = launcher_view(),
            })
        end
        return windows
    end,
})
