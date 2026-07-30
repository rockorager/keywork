local kw = require("keywork")

local M = {}

M.usage = [[Usage: keywork-shell background <options...>

  -c, --color RRGGBB     Set the background color.
  -h, --help             Show this help message and quit.
  -i, --image <path>     Set the image to display.
  -m, --mode <mode>      Set stretch, fill, fit, center, or solid_color.
  -o, --output <name>    Select an output, or * for all outputs.

The tile mode supported by swaybg is not implemented yet.
]]

local fit_by_mode = {
    stretch = "fill",
    fill = "cover",
    fit = "contain",
    center = "none",
}

---@alias BackgroundMode 'stretch' | 'fill' | 'fit' | 'center' | 'solid_color'
---@class BackgroundProfile
---@field image? string
---@field mode?  BackgroundMode
---@field color? integer

local retained = kw.app.hot.state("shell.background", {
    init = function()
        return {
            profiles = { ["*"] = {} },
            enabled = false,
        }
    end,
})
---@cast retained { profiles: table<string, BackgroundProfile>, enabled: boolean }
local profiles = retained.profiles

local function arguments(payload)
    local args = {}
    if payload == "" then return args end
    for value in (payload .. "\n"):gmatch("(.-)\n") do
        args[#args + 1] = value
    end
    return args
end

---@param args   string[]
---@param index  integer
---@param option string
---@param inline string?
---@return string? value, integer index, string? error
local function option_value(args, index, option, inline)
    if inline ~= nil then
        if inline == "" then return nil, index, "option '" .. option .. "' requires a value" end
        return inline, index
    end
    local value = args[index + 1]
    if value == nil then return nil, index, "option '" .. option .. "' requires a value" end
    return value, index + 1
end

---@param value string
---@return integer? color, string? error
local function parse_color(value)
    local hex = value:gsub("^#", "")
    if not hex:match("^[%da-fA-F][%da-fA-F][%da-fA-F][%da-fA-F][%da-fA-F][%da-fA-F]$") then
        return nil, "invalid color '" .. value .. "' (expected [#]rrggbb)"
    end
    local color = tonumber(hex, 16)
    if not color then return nil, "invalid color '" .. value .. "'" end
    return 0xff000000 + color
end

---@param value string
---@return BackgroundMode? mode, string? error
local function parse_mode(value)
    if value == "tile" then return nil, "mode 'tile' is not supported yet" end
    if value ~= "solid_color" and not fit_by_mode[value] then
        return nil, "invalid mode '" .. value .. "'"
    end
    return value --[[@as BackgroundMode]]
end

---@param payload string
---@return table<string, BackgroundProfile>? profiles, string? error
local function parse(payload)
    local args = arguments(payload)
    local parsed = { ["*"] = {} }
    local selected = "*"
    local index = 1
    while index <= #args do
        local option = assert(args[index])
        local name, inline = option:match("^(%-%-[^=]+)=(.*)$")
        name = name or option

        local value, err
        if name == "-h" or name == "--help" then
            return nil, "help is only available from the command line"
        elseif name == "-o" or name == "--output" then
            local output
            output, index, err = option_value(args, index, name, inline)
            if err then return nil, err end
            selected = assert(output)
            if selected == "" then return nil, "output name must not be empty" end
            parsed[selected] = parsed[selected] or {}
        elseif name == "-i" or name == "--image" then
            value, index, err = option_value(args, index, name, inline)
            if err then return nil, err end
            local profile = assert(parsed[selected])
            profile.image = assert(value)
        elseif name == "-m" or name == "--mode" then
            value, index, err = option_value(args, index, name, inline)
            if err then return nil, err end
            local mode
            mode, err = parse_mode(assert(value))
            if err then return nil, err end
            local profile = assert(parsed[selected])
            profile.mode = assert(mode)
        elseif name == "-c" or name == "--color" then
            value, index, err = option_value(args, index, name, inline)
            if err then return nil, err end
            local color
            color, err = parse_color(assert(value))
            if err then return nil, err end
            local profile = assert(parsed[selected])
            profile.color = assert(color)
        else
            return nil, "unknown option '" .. option .. "'"
        end
        index = index + 1
    end
    return parsed
end

function M.configure(payload)
    local parsed, err = parse(payload)
    if not parsed then return false, err end
    profiles = parsed
    retained.profiles = parsed
    retained.enabled = true
    return true
end

local function setting(output_name, key, fallback)
    local profile = profiles[output_name]
    if profile and profile[key] ~= nil then return profile[key] end
    local defaults = profiles["*"]
    if defaults[key] ~= nil then return defaults[key] end
    return fallback
end

local Background = kw.stateful({
    hot_id = "Background",
    hot_version = 1,
    build = function(self, context)
        local output = self.props.output
        local width = math.max(1, math.floor(context.window_width))
        local height = math.max(1, math.floor(context.window_height))
        local mode = setting(output, "mode", "stretch")
        local color = setting(output, "color", context.theme.colors.background)
        local image = setting(output, "image", nil)
        local content = kw.spacer()
        if image and mode ~= "solid_color" then
            content = kw.image({
                path = image,
                width = width,
                height = height,
                fit = fit_by_mode[mode],
                align = "center",
                cache = "frame",
            })
        end
        return kw.container({
            background = color,
            child = kw.sized_box({
                width = width,
                height = height,
                child = content,
            }),
        })
    end,
})

function M.append_windows(windows, outputs)
    if not retained.enabled then return end
    for _, output in ipairs(outputs) do
        windows[#windows + 1] = kw.window({
            id = "background:" .. output.name,
            output = output.name,
            width = 0,
            height = 0,
            layer_shell = {
                layer = "background",
                anchor = { "top", "bottom", "left", "right" },
                exclusive_zone = -1,
                pointer = "none",
            },
            child = Background({ output = output.name }),
        })
    end
end

return M
