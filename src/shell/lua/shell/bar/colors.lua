local M = {}

-- Palette derived from the resolved theme so the bar adapts to the
-- system color scheme, matching the keywork-launcher card look. The
-- theme's space scale rides along so widgets built outside build()
-- (async update hooks) can reach the design tokens too.
local function palette(theme)
    local scheme = theme.colors
    local result = {
        background = math.floor(scheme.surface % 0x1000000 + 0xFF000000),
        border = scheme.border,
        foreground = scheme.text,
        muted = scheme.text_secondary,
        subtle = scheme.text_tertiary,
        error = scheme.danger,
        on_error = scheme.on_danger,
        success = scheme.success,
        warning = scheme.warning,
        danger = scheme.danger,
        accent = scheme.accent,
        selection = scheme.accent,

        space = theme.space,
    }

    -- Bar surfaces do not request keyboard input, so their buttons should not
    -- retain focus decoration after pointer activation.
    local bar_theme = {}
    for key, value in pairs(theme) do
        bar_theme[key] = value
    end
    bar_theme.components = {}
    for key, value in pairs(theme.components) do
        bar_theme.components[key] = value
    end
    local button = {}
    for key, value in pairs(theme.components.button) do
        button[key] = value
    end
    button.focused_border = nil
    bar_theme.components.button = button
    result.theme = bar_theme

    return result
end

M.palette = palette

return M
