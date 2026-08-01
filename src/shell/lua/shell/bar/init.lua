local kw = require("keywork")

local audio = require("shell.audio")
local colors = require("shell.bar.colors")
local network = require("shell.bar.network")
local status = require("shell.bar.status")
local tray = require("shell.bar.tray")
local util = require("shell.bar.util")
local workspaces = require("shell.bar.workspaces")

local M = {}

M.height = 40

---@alias shell.BarOutputSelection 'all' | 'first' | string | string[]

---@class shell.BarActions
---@field open_audio_settings? fun()
---@field toggle_launcher?     fun()

---@class shell.BarItemContext
---@field output          string
---@field output_index    integer
---@field is_first_output boolean
---@field theme           keywork.Theme
---@field colors          ShellBarPalette
---@field actions         shell.BarActions

---@class shell.BarItem
---@field id       string
---@field widget   fun(context: shell.BarItemContext): keywork.Widget
---@field outputs? shell.BarOutputSelection
---@field _tag     table

---@class shell.BarItemOptions
---@field id       string
---@field widget   fun(context: shell.BarItemContext): keywork.Widget
---@field outputs? shell.BarOutputSelection

---@class shell.BarBuiltinOptions
---@field id?      string
---@field outputs? shell.BarOutputSelection

---@class shell.BarBatteryOptions: shell.BarBuiltinOptions
---@field show_percent? boolean

---@class shell.BarClockOptions: shell.BarBuiltinOptions
---@field format? string `os.date` format; defaults to the built-in bar format.

---@class shell.BarPillOptions
---@field id           string
---@field icon         string
---@field label?       string
---@field color?       keywork.Color
---@field tone?        'danger'
---@field on_activate? fun(event: keywork.TapEvent)

---@class shell.BarOptions
---@field height? integer
---@field left?   shell.BarItem[]
---@field right?  shell.BarItem[]

---@class shell.ResolvedBarOptions
---@field height integer
---@field left   shell.BarItem[]
---@field right  shell.BarItem[]

local item_tag = {}

local function validate(options, allowed, name)
    if options == nil then
        options = {}
    end
    assert(type(options) == "table", name .. " options must be a table")
    for key in pairs(options) do
        if not allowed[key] then
            error(("unknown %s option: %s"):format(name, tostring(key)), 3)
        end
    end
    return options
end

local function validate_outputs(outputs, name)
    if outputs == nil then
        return
    elseif type(outputs) == "string" then
        assert(outputs ~= "", name .. " output must not be empty")
        return
    end
    assert(type(outputs) == "table", name .. " outputs must be a string or list of output names")
    local count = 0
    for index, output in pairs(outputs) do
        assert(type(index) == "number" and index >= 1 and index % 1 == 0, name .. " outputs must be a list")
        assert(type(output) == "string" and output ~= "", name .. " output " .. index .. " must be a string")
        count = count + 1
    end
    assert(count > 0, name .. " outputs list must not be empty")
    assert(count == #outputs, name .. " outputs list must not contain gaps")
end

---@param options shell.BarItemOptions
---@return shell.BarItem
function M.item(options)
    options = validate(options, { id = true, widget = true, outputs = true }, "bar item")
    assert(type(options.id) == "string" and options.id ~= "", "bar item id must be a non-empty string")
    assert(type(options.widget) == "function", "bar item widget must be a function")
    validate_outputs(options.outputs, "bar item " .. options.id)
    return {
        id = options.id,
        widget = options.widget,
        outputs = options.outputs,
        _tag = item_tag,
    }
end

local builtin_options = { id = true, outputs = true }

local function builtin(options, name, default_id, widget)
    options = validate(options, builtin_options, "bar." .. name)
    local id = options.id
    if id == nil then id = default_id end
    return M.item({
        id = id,
        outputs = options.outputs,
        widget = widget,
    })
end

---@param options? shell.BarBuiltinOptions
---@return shell.BarItem
function M.workspaces(options)
    return builtin(options, "workspaces", "workspaces", function(context)
        return workspaces.Workspaces({
            colors = context.colors,
            output = context.output,
        })
    end)
end

---@param options? shell.BarBuiltinOptions
---@return shell.BarItem
function M.tray(options)
    options = validate(options, builtin_options, "bar.tray")
    local id = options.id
    if id == nil then id = "tray" end
    local outputs = options.outputs
    if outputs == nil then outputs = "first" end
    validate_outputs(outputs, "bar.tray")
    assert(
        outputs ~= "all" and (type(outputs) ~= "table" or #outputs == 1),
        "bar.tray may appear on only one output"
    )
    return M.item({
        id = id,
        outputs = outputs,
        widget = function(context)
            return tray.Items({ colors = context.colors })
        end,
    })
end

---@param options? shell.BarBuiltinOptions
---@return shell.BarItem
function M.volume(options)
    return builtin(options, "volume", "volume", function(context)
        return audio.Audio({
            colors = context.colors,
            on_open_settings = context.actions.open_audio_settings,
        })
    end)
end

---@param options? shell.BarBuiltinOptions
---@return shell.BarItem
function M.network(options)
    return builtin(options, "network", "network", function(context)
        return network.Network({ colors = context.colors })
    end)
end

---@param options? shell.BarBatteryOptions
---@return shell.BarItem
function M.battery(options)
    options = validate(options, { id = true, outputs = true, show_percent = true }, "bar.battery")
    assert(
        options.show_percent == nil or type(options.show_percent) == "boolean",
        "bar.battery show_percent must be boolean"
    )
    local id = options.id
    if id == nil then id = "battery" end
    local show_percent = options.show_percent
    return M.item({
        id = id,
        outputs = options.outputs,
        widget = function(context)
            return status.Battery({
                colors = context.colors,
                show_percent = show_percent,
            })
        end,
    })
end

---@param options? shell.BarClockOptions
---@return shell.BarItem
function M.clock(options)
    options = validate(options, { id = true, outputs = true, format = true }, "bar.clock")
    assert(options.format == nil or type(options.format) == "string", "bar.clock format must be a string")
    local id = options.id
    if id == nil then id = "clock" end
    local format = options.format
    return M.item({
        id = id,
        outputs = options.outputs,
        widget = function(context)
            return status.Clock({
                colors = context.colors,
                format = format,
            })
        end,
    })
end

---@param options shell.BarPillOptions
---@return keywork.Widget
function M.pill(options)
    options = validate(
        options,
        { id = true, icon = true, label = true, color = true, tone = true, on_activate = true },
        "bar.pill"
    )
    assert(type(options.id) == "string" and options.id ~= "", "bar.pill id must be a non-empty string")
    assert(type(options.icon) == "string" and options.icon ~= "", "bar.pill icon must be a non-empty string")
    return util.status_pill(options.id, options.icon, options.label, options.color, {
        tone = options.tone,
        on_activate = options.on_activate,
    })
end

local function item_visible(item, context)
    local outputs = item.outputs
    if outputs == nil or outputs == "all" then
        return true
    elseif outputs == "first" then
        return context.is_first_output
    elseif type(outputs) == "string" then
        return outputs == context.output
    end
    for _, output in ipairs(outputs) do
        if output == context.output then
            return true
        end
    end
    return false
end

local function build_items(items, context)
    local children = {}
    for _, item in ipairs(items) do
        if item_visible(item, context) then
            local widget = item.widget(context)
            assert(type(widget) == "table", "bar item " .. item.id .. " did not return a widget")
            children[#children + 1] = kw.keyed(item.id, widget)
        end
    end
    return children
end

local function validate_items(items, name, ids)
    assert(type(items) == "table", name .. " must be a list of bar items")
    local count = 0
    for index in pairs(items) do
        assert(type(index) == "number" and index >= 1 and index % 1 == 0, name .. " must be a list of bar items")
        count = count + 1
    end
    assert(count == #items, name .. " must not contain gaps")
    for index, item in ipairs(items) do
        assert(type(item) == "table" and item._tag == item_tag, name .. " item " .. index .. " is not a bar item")
        assert(not ids[item.id], "duplicate bar item id: " .. item.id)
        ids[item.id] = true
    end
    return items
end

local function default_status()
    local items = { M.volume(), M.network(), M.battery(), M.clock() }
    return M.item({
        id = "status",
        widget = function(context)
            return kw.row({
                spacing = context.colors.space[2],
                align = "baseline",
                children = build_items(items, context),
            })
        end,
    })
end

---@param options? shell.BarOptions
---@return shell.ResolvedBarOptions
function M.configure(options)
    options = validate(options, { height = true, left = true, right = true }, "shell bar")
    local height = options.height
    if height == nil then height = M.height end
    assert(
        type(height) == "number" and height > 0 and height % 1 == 0,
        "shell bar height must be a positive integer"
    )
    local left = options.left
    if left == nil then
        left = { M.workspaces() }
    end
    local right = options.right
    if right == nil then
        right = { M.tray(), default_status() }
    end
    local ids = {}
    validate_items(left, "shell bar left", ids)
    validate_items(right, "shell bar right", ids)
    return { height = height, left = left, right = right }
end

-- A stable palette identity keeps child update() hooks from refreshing on
-- rebuilds that did not change colors. Include resolved color values so live
-- theme or accent changes within one light/dark scheme replace the palette.
local cached_palette_key
---@type ShellBarPalette?
local cached_palette
---@param theme keywork.Theme
---@return string
local function palette_key(theme)
    local entries = {}
    for name, value in pairs(theme.colors or {}) do
        if type(value) == "number" then
            entries[#entries + 1] = name .. "=" .. value
        end
    end
    table.sort(entries)
    return theme.color_scheme .. ":" .. table.concat(entries, ",")
end

---@param theme keywork.Theme
---@return ShellBarPalette
local function palette_for(theme)
    local key = palette_key(theme)
    if cached_palette_key ~= key then
        cached_palette_key = key
        cached_palette = colors.palette(theme)
    end
    return assert(cached_palette)
end

-- One bar per output. Item descriptors turn the output and shared shell
-- actions into ordinary retained widgets; their effects remain owned by the
-- widgets' normal lifecycle scopes.
local Bar = kw.stateful({
    hot_id = "Bar",
    hot_version = 1,
    build = function(self, context)
        local theme = context.theme
        local palette = palette_for(theme)
        ---@type shell.BarItemContext
        local item_context = {
            output = self.props.output,
            output_index = self.props.output_index,
            is_first_output = self.props.output_index == 1,
            theme = palette.theme,
            colors = palette,
            actions = self.props.actions or {},
        }
        local children = build_items(self.props.config.left, item_context)
        children[#children + 1] = kw.spacer()
        for _, child in ipairs(build_items(self.props.config.right, item_context)) do
            children[#children + 1] = child
        end

        return kw.theme({
            data = palette.theme,
            child = kw.column({
                align = "stretch",
                children = {
                    kw.expanded({
                        child = kw.container({
                            background = palette.background,
                            vertical_align = "center",
                            padding = { x = theme.space[2], y = theme.space[1] },
                            child = kw.row({
                                spacing = theme.space[3],
                                align = "center",
                                children = children,
                            }),
                        }),
                    }),
                    kw.separator({}),
                },
            }),
        })
    end,
})

M.Bar = Bar

return M
