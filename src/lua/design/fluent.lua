-- Keywork's Fluent-derived widget design profile. These are logical pixels at
-- 100% scale. The final two spacing values are Keywork layout extensions;
-- Fluent's canonical spacing ramp ends at 32.
local space = { 4, 8, 12, 16, 20, 24, 32, 40, 48 }
local font_size = { 12, 14, 16, 20, 24, 28, 32, 40, 68 }
local line_height = { 16, 20, 22, 28, 32, 36, 40, 52, 92 }
local radius = { 2, 4, 6, 8, 12, 16 }

local brand = {
    brand10 = 0xff061724,
    brand20 = 0xff082338,
    brand30 = 0xff0a2e4a,
    brand40 = 0xff0c3b5e,
    brand50 = 0xff0e4775,
    brand60 = 0xff0f548c,
    brand70 = 0xff115ea3,
    brand80 = 0xff0f6cbd,
    brand90 = 0xff2886de,
    brand100 = 0xff479ef5,
    brand110 = 0xff62abf5,
    brand120 = 0xff77b7f7,
    brand130 = 0xff96c6fa,
    brand140 = 0xffb4d6fa,
    brand150 = 0xffcfe4fa,
    brand160 = 0xffebf3fc,
}

local function add_brand(colors)
    for name, value in pairs(brand) do
        colors[name] = value
    end
end

local function add_compatibility_aliases(colors)
    -- Stable Keywork semantic roles consumed by applications and the shell.
    colors.text = "neutral_foreground1"
    colors.text_secondary = "neutral_foreground2"
    colors.text_tertiary = "neutral_foreground3"
    colors.placeholder = "neutral_foreground4"
    colors.border = "neutral_stroke1"
    colors.panel_border = "neutral_stroke2"
    colors.separator = "neutral_stroke2"
    colors.opaque_separator = "neutral_stroke2"
    colors.fill = "neutral_background4"
    colors.fill_secondary = "neutral_background3"
    colors.accent = "brand_background"
    colors.focus8 = "brand_stroke1"
    colors.on_accent = "white"
    colors.info = "brand_foreground1"
    colors.on_success = "white"
    colors.on_warning = "black"
    colors.on_danger = "white"
    colors.on_info = "white"

    -- General names retained by the native bridge and older applications.
    colors.label = "text"
    colors.secondary_label = "text_secondary"
    colors.tertiary_label = "text_tertiary"
    colors.system_background = "background"
    colors.secondary_system_background = "surface"
    colors.tertiary_system_background = "surface_high"
    colors.system_fill = "fill"
    colors.secondary_system_fill = "fill_secondary"
    colors.foreground = "text"
    colors.muted = "text_secondary"
    colors.primary = "accent"
    colors.on_primary = "on_accent"
    colors.error = "danger"
    colors.on_error = "on_danger"
end

local function light_colors()
    local colors = {
        black = 0xff000000,
        white = 0xffffffff,

        neutral_foreground1 = 0xff242424,
        neutral_foreground2 = 0xff424242,
        neutral_foreground3 = 0xff616161,
        neutral_foreground4 = 0xff707070,
        neutral_foreground_disabled = 0xffbdbdbd,

        neutral_background1 = 0xffffffff,
        neutral_background1_hover = 0xfff5f5f5,
        neutral_background1_pressed = 0xffe0e0e0,
        neutral_background1_selected = 0xffebebeb,
        neutral_background2 = 0xfffafafa,
        neutral_background3 = 0xfff5f5f5,
        neutral_background4 = 0xfff0f0f0,
        neutral_background5 = 0xffebebeb,
        neutral_background6 = 0xffe6e6e6,
        neutral_background_disabled = 0xfff0f0f0,

        subtle_background = 0x00000000,
        subtle_background_hover = 0xfff5f5f5,
        subtle_background_pressed = 0xffe0e0e0,
        subtle_background_selected = 0xffebebeb,
        neutral_stroke_accessible = 0xff616161,
        neutral_stroke1 = 0xffd1d1d1,
        neutral_stroke2 = 0xffe0e0e0,
        neutral_stroke3 = 0xfff0f0f0,
        neutral_stroke_disabled = 0xffe0e0e0,

        brand_background = "brand80",
        brand_background_hover = "brand70",
        brand_background_pressed = "brand40",
        brand_background_selected = "brand60",
        brand_background2 = "brand160",
        brand_foreground1 = "brand80",
        brand_foreground2 = "brand70",
        brand_stroke1 = "brand80",
        brand_stroke2 = "brand140",

        success = 0xff0e700e,
        warning = 0xffbc4b09,
        danger = 0xffb10e1c,
        scrollbar_overlay = 0x80000000,

        background = "neutral_background2",
        surface = "neutral_background1",
        surface_high = "neutral_background1",
        surface_low = "neutral_background3",
        backdrop_surface = 0x99ffffff,
    }
    add_brand(colors)
    add_compatibility_aliases(colors)
    return colors
end

local function dark_colors()
    local colors = {
        black = 0xff000000,
        white = 0xffffffff,

        neutral_foreground1 = 0xffffffff,
        neutral_foreground2 = 0xffd6d6d6,
        neutral_foreground3 = 0xffadadad,
        neutral_foreground4 = 0xff999999,
        neutral_foreground_disabled = 0xff5c5c5c,

        neutral_background1 = 0xff292929,
        neutral_background1_hover = 0xff3d3d3d,
        neutral_background1_pressed = 0xff1f1f1f,
        neutral_background1_selected = 0xff383838,
        neutral_background2 = 0xff1f1f1f,
        neutral_background3 = 0xff141414,
        neutral_background4 = 0xff0a0a0a,
        neutral_background5 = 0xff000000,
        neutral_background6 = 0xff333333,
        neutral_background_disabled = 0xff141414,

        subtle_background = 0x00000000,
        subtle_background_hover = 0xff383838,
        subtle_background_pressed = 0xff2e2e2e,
        subtle_background_selected = 0xff333333,
        neutral_stroke_accessible = 0xffadadad,
        neutral_stroke1 = 0xff666666,
        neutral_stroke2 = 0xff525252,
        neutral_stroke3 = 0xff3d3d3d,
        neutral_stroke_disabled = 0xff424242,

        brand_background = "brand70",
        brand_background_hover = "brand80",
        brand_background_pressed = "brand40",
        brand_background_selected = "brand60",
        brand_background2 = "brand20",
        brand_foreground1 = "brand100",
        brand_foreground2 = "brand110",
        brand_stroke1 = "brand100",
        brand_stroke2 = "brand50",

        success = 0xff54b054,
        warning = 0xfffaa06b,
        danger = 0xffdc626d,
        scrollbar_overlay = 0x99ffffff,

        background = "neutral_background2",
        surface = "neutral_background1",
        surface_high = "neutral_background6",
        surface_low = "neutral_background3",
        backdrop_surface = 0x99000000,
    }
    add_brand(colors)
    add_compatibility_aliases(colors)
    return colors
end

local function shadows(dark)
    local ambient = dark and 0x3d000000 or 0x1f000000
    local key = dark and 0x47000000 or 0x24000000
    return {
        [2] = { { blur = 2, color = ambient }, { offset_y = 1, blur = 2, color = key } },
        [3] = { { blur = 2, color = ambient }, { offset_y = 2, blur = 4, color = key } },
        [4] = { { blur = 2, color = ambient }, { offset_y = 4, blur = 8, color = key } },
        [5] = { { blur = 2, color = ambient }, { offset_y = 8, blur = 16, color = key } },
        [6] = { { blur = 8, color = ambient }, { offset_y = 14, blur = 28, color = key } },
    }
end

return {
    schemes = {
        light = { colors = light_colors(), shadow = shadows(false) },
        dark = { colors = dark_colors(), shadow = shadows(true) },
    },
    text = {
        body = { size = 14, line_height = 20 },
        label = { size = 14, line_height = 20 },
        title = { size = 20, line_height = 28 },
    },
    space = space,
    font_size = font_size,
    line_height = line_height,
    radius = radius,
    components = {
        button = {
            padding_x = 12,
            padding_y = 6,
            radius = 4,
            default = { background = "brand_background", foreground = "on_accent" },
            hover = { background = "brand_background_hover", foreground = "on_accent" },
            pressed = { background = "brand_background_pressed", foreground = "on_accent" },
            disabled = {
                background = "neutral_background_disabled",
                foreground = "neutral_foreground_disabled",
            },
            focused = { border = "brand_stroke1", border_width = 2 },
        },
        input = {
            padding_x = 12,
            padding_y = 6,
            radius = 4,
            font_size = 14,
            line_height = 20,
            background = "neutral_background1",
            foreground = "neutral_foreground1",
            placeholder = "neutral_foreground4",
            border = "neutral_stroke1",
            focused_border = "brand_stroke1",
        },
        chip = {
            padding_x = 8,
            padding_y = 4,
            radius = 4,
            min_height = 24,
            font_size = 12,
            line_height = 16,
            icon_size = 12,
            gap = 4,
            background = "brand_background2",
            foreground = "brand_foreground2",
            hover_background = "brand_background2",
            pressed_background = "brand_background2",
            focused_border = "brand_stroke1",
            focused_border_width = 2,
            selected_background = "brand_background",
            selected_foreground = "on_accent",
            selected_hover_background = "brand_background_hover",
            selected_pressed_background = "brand_background_pressed",
        },
        menu = {
            background = "neutral_background1",
            border = "neutral_stroke2",
            border_width = 1,
            radius = 4,
            padding = 4,
            shadow = 5,
            item = {
                padding_x = 6,
                padding_y = 6,
                min_height = 32,
                radius = 4,
                font_size = 14,
                line_height = 20,
                hover_background = "subtle_background_hover",
                pressed_background = "subtle_background_pressed",
                selected_background = "subtle_background_selected",
                selected_hover_background = "subtle_background_hover",
                selected_pressed_background = "subtle_background_pressed",
            },
            label = {
                padding_x = 6,
                padding_y = 6,
                min_height = 32,
                font_size = 14,
                line_height = 20,
                foreground = "neutral_foreground3",
            },
            separator = { color = "neutral_stroke2", thickness = 1, margin = 12, inset = 4 },
        },
        separator = { color = "neutral_stroke2", thickness = 1 },
        scrollbar = { track = "subtle_background", thumb = "scrollbar_overlay" },
    },
}
