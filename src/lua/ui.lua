local ui = {}

-- The authoritative built-in profile lives separately from generic theme and
-- widget mechanics so additional design profiles do not duplicate this API.
local default_theme = require("keywork.design.fluent")

local function copy_table(value)
    local result = {}
    for key, child in pairs(value or {}) do
        if type(child) == "table" then
            result[key] = copy_table(child)
        else
            result[key] = child
        end
    end
    return result
end

local function merge_table(base, overrides)
    local result = copy_table(base)
    for key, value in pairs(overrides or {}) do
        if type(value) == "table" and type(result[key]) == "table" then
            result[key] = merge_table(result[key], value)
        else
            result[key] = value
        end
    end
    return result
end

function ui.theme_data(options)
    options = options or {}
    local result = merge_table(default_theme, options)
    -- A custom font size without a matching line height keeps the historical
    -- font-metrics fallback instead of inheriting an unrelated default pair.
    for role, style in pairs(options.text or {}) do
        if type(style) == "table" and (style.size ~= nil or style.font_size ~= nil) and style.line_height == nil then
            result.text[role].line_height = nil
        end
    end
    return result
end

local function resolve_ref(value, tokens)
    if type(value) == "string" then
        return tokens[value]
    end
    return value
end

local function resolve_token(name, tokens, resolved, resolving)
    if resolved[name] ~= nil then
        return resolved[name]
    end

    if resolving[name] then
        error("cyclic color alias: " .. name)
    end

    local value = tokens[name]
    if type(value) == "string" then
        if tokens[value] == nil then
            error("unknown color alias: " .. name .. " -> " .. value)
        end
        resolving[name] = true
        value = resolve_token(value, tokens, resolved, resolving)
        resolving[name] = nil
    end

    resolved[name] = value
    return value
end

local function resolve_colors(colors)
    local resolved = {}
    for name in pairs(colors or {}) do
        resolve_token(name, colors, resolved, {})
    end
    return resolved
end

local function resolve_color(value, colors)
    return resolve_ref(value, colors)
end

local function resolve_space(value, space)
    return resolve_ref(value, space)
end

local function resolve_radius(value, radius)
    return resolve_ref(value, radius)
end

local function resolve_shadows(shadows, colors)
    local result = {}
    for level, layers in pairs(shadows or {}) do
        result[level] = {}
        for index, layer in ipairs(layers) do
            result[level][index] = {
                color = resolve_color(layer.color, colors),
                offset_x = layer.offset_x or 0,
                offset_y = layer.offset_y or 0,
                blur = layer.blur or 0,
                spread = layer.spread or 0,
            }
        end
    end
    return result
end

local function resolve_button(button, colors, space, radius)
    button = button or {}
    return {
        padding_x = resolve_space(button.padding_x, space),
        padding_y = resolve_space(button.padding_y, space),
        radius = resolve_radius(button.radius, radius),
        default = {
            background = resolve_color(button.default and button.default.background, colors),
            foreground = resolve_color(button.default and button.default.foreground, colors),
        },
        hover = {
            background = resolve_color(button.hover and button.hover.background, colors),
            foreground = resolve_color(button.hover and button.hover.foreground, colors),
        },
        pressed = {
            background = resolve_color(button.pressed and button.pressed.background, colors),
            foreground = resolve_color(button.pressed and button.pressed.foreground, colors),
        },
        disabled = {
            background = resolve_color(button.disabled and button.disabled.background, colors),
            foreground = resolve_color(button.disabled and button.disabled.foreground, colors),
        },
        focused = {
            border = resolve_color(button.focused and button.focused.border, colors),
            border_width = button.focused and button.focused.border_width,
        },
    }
end

local function resolve_input(input, colors, space, radius)
    input = input or {}
    return {
        padding_x = resolve_space(input.padding_x, space),
        padding_y = resolve_space(input.padding_y, space),
        radius = resolve_radius(input.radius, radius),
        font_size = input.font_size,
        line_height = input.line_height,
        background = resolve_color(input.background, colors),
        foreground = resolve_color(input.foreground, colors),
        placeholder = resolve_color(input.placeholder, colors),
        border = resolve_color(input.border, colors),
        focused_border = resolve_color(input.focused_border, colors),
    }
end

local function resolve_chip(chip, colors, space, radius)
    chip = chip or {}
    return {
        padding_x = resolve_space(chip.padding_x, space),
        padding_y = resolve_space(chip.padding_y, space),
        radius = resolve_radius(chip.radius, radius),
        min_height = resolve_space(chip.min_height, space),
        font_size = chip.font_size,
        line_height = chip.line_height,
        icon_size = resolve_space(chip.icon_size, space),
        gap = resolve_space(chip.gap, space),
        background = resolve_color(chip.background, colors),
        foreground = resolve_color(chip.foreground, colors),
        hover_background = resolve_color(chip.hover_background, colors),
        pressed_background = resolve_color(chip.pressed_background, colors),
        focused_border = resolve_color(chip.focused_border, colors),
        focused_border_width = chip.focused_border_width,
        selected_background = resolve_color(chip.selected_background, colors),
        selected_foreground = resolve_color(chip.selected_foreground, colors),
        selected_hover_background = resolve_color(chip.selected_hover_background, colors),
        selected_pressed_background = resolve_color(chip.selected_pressed_background, colors),
    }
end

local function resolve_menu(menu, colors, space, radius, shadow)
    menu = menu or {}
    local item = menu.item or {}
    local label = menu.label or {}
    local separator = menu.separator or {}
    return {
        background = resolve_color(menu.background, colors),
        border = resolve_color(menu.border, colors),
        border_width = menu.border_width,
        radius = resolve_radius(menu.radius, radius),
        padding = resolve_space(menu.padding, space),
        shadow = type(menu.shadow) == "number" and shadow[menu.shadow] or menu.shadow,
        item = {
            padding_x = resolve_space(item.padding_x, space),
            padding_y = resolve_space(item.padding_y, space),
            min_height = resolve_space(item.min_height, space),
            radius = resolve_radius(item.radius, radius),
            font_size = item.font_size,
            line_height = item.line_height,
            hover_background = resolve_color(item.hover_background, colors),
            pressed_background = resolve_color(item.pressed_background, colors),
            selected_background = resolve_color(item.selected_background, colors),
            selected_hover_background = resolve_color(item.selected_hover_background, colors),
            selected_pressed_background = resolve_color(item.selected_pressed_background, colors),
        },
        label = {
            padding_x = resolve_space(label.padding_x, space),
            padding_y = resolve_space(label.padding_y, space),
            min_height = resolve_space(label.min_height, space),
            font_size = label.font_size,
            line_height = label.line_height,
            foreground = resolve_color(label.foreground, colors),
        },
        separator = {
            color = resolve_color(separator.color, colors),
            thickness = separator.thickness,
            margin = resolve_space(separator.margin, space),
            inset = resolve_space(separator.inset, space),
        },
    }
end

local function resolve_separator(separator, colors)
    separator = separator or {}
    return {
        color = resolve_color(separator.color, colors),
        thickness = separator.thickness,
    }
end

local function resolve_scrollbar(scrollbar, colors)
    scrollbar = scrollbar or {}
    return {
        track = resolve_color(scrollbar.track, colors),
        thumb = resolve_color(scrollbar.thumb, colors),
    }
end

function ui.resolve_theme(theme, state_or_scheme)
    theme = theme or default_theme
    local color_scheme = "light"
    if type(state_or_scheme) == "table" then
        color_scheme = state_or_scheme.color_scheme or color_scheme
    elseif type(state_or_scheme) == "string" then
        color_scheme = state_or_scheme
    end
    if color_scheme == "no-preference" then
        color_scheme = "light"
    end

    local scheme = theme.schemes[color_scheme] or theme.schemes.light
    local colors = resolve_colors(scheme.colors)
    local space = copy_table(theme.space or {})
    local font_size = copy_table(theme.font_size or {})
    local line_height = copy_table(theme.line_height or {})
    local radius = copy_table(theme.radius or {})
    local shadow = resolve_shadows(scheme.shadow or theme.shadow, colors)
    local components = {
        button = resolve_button(theme.components and theme.components.button, colors, space, radius),
        input = resolve_input(theme.components and theme.components.input, colors, space, radius),
        chip = resolve_chip(theme.components and theme.components.chip, colors, space, radius),
        menu = resolve_menu(theme.components and theme.components.menu, colors, space, radius, shadow),
        separator = resolve_separator(theme.components and theme.components.separator, colors),
        scrollbar = resolve_scrollbar(theme.components and theme.components.scrollbar, colors),
    }

    return {
        color_scheme = color_scheme,
        colors = colors,
        text = copy_table(theme.text or {}),
        space = space,
        font_size = font_size,
        line_height = line_height,
        radius = radius,
        shadow = shadow,
        components = components,
    }
end

function ui.theme_for(state, theme)
    return ui.resolve_theme(theme or default_theme, state)
end

function ui.text(value, style)
    style = style or {}
    return {
        type = "text",
        value = value,
        color = style.color,
        size = style.size,
        font_size = style.font_size,
        line_height = style.line_height,
        role = style.role,
        max_lines = style.max_lines,
        overflow = style.overflow,
        line_break = style.line_break,
    }
end

function ui.label(value, options)
    options = options or {}
    return ui.text(value, {
        color = options.color,
        size = options.size,
        font_size = options.font_size,
        line_height = options.line_height,
        role = options.role or "label",
        max_lines = options.max_lines,
        overflow = options.overflow,
        line_break = options.line_break,
    })
end

function ui.keyed(key, child)
    return {
        type = "keyed",
        key = key,
        child = child,
    }
end

function ui.stateful(spec)
    local build = spec.build
    if build then
        spec = setmetatable({
            build = function(self, context)
                context = context or {}
                context.theme = context.theme or ui.theme_for(context)
                return build(self, context)
            end,
        }, { __index = spec })
    end

    return function(props)
        props = props or {}
        local widget = {
            type = "stateful",
            spec = spec,
            props = props,
        }
        if props.key then
            return ui.keyed(props.key, widget)
        end
        return widget
    end
end

function ui.theme(options)
    options = options or {}
    return {
        type = "theme",
        theme = options.data or options.theme,
        child = options.child,
    }
end

function ui.default_text_style(options)
    options = options or {}
    return {
        type = "default_text_style",
        color = options.color,
        size = options.size,
        font_size = options.font_size,
        line_height = options.line_height,
        child = options.child,
    }
end

function ui.icon_theme(options)
    options = options or {}
    return {
        type = "icon_theme",
        color = options.color,
        size = options.size,
        symbolic = options.symbolic,
        child = options.child,
    }
end

function ui.box(style, child)
    style = style or {}
    return {
        type = "box",
        background = style.background,
        border = style.border,
        border_width = style.border_width,
        radius = style.radius,
        shadow = style.shadow,
        min_width = style.min_width,
        min_height = style.min_height,
        align = style.align,
        horizontal_align = style.horizontal_align,
        vertical_align = style.vertical_align,
        child = child,
    }
end

function ui.container(options, child)
    options = options or {}
    if options.child then
        child = options.child
    end
    if options.padding then
        local padding = options.padding
        if type(padding) == "number" then
            child = ui.padding({ all = padding, child = child })
        else
            child = ui.padding({
                all = padding.all,
                x = padding.x,
                y = padding.y,
                left = padding.left,
                right = padding.right,
                top = padding.top,
                bottom = padding.bottom,
                child = child,
            })
        end
    end
    return ui.box({
        background = options.background,
        border = options.border,
        border_width = options.border_width,
        radius = options.radius,
        shadow = options.shadow,
        min_width = options.min_width,
        min_height = options.min_height,
        align = options.align,
        horizontal_align = options.horizontal_align,
        vertical_align = options.vertical_align,
    }, child)
end

function ui.gesture(options)
    return {
        type = "gesture",
        id = options.id,
        child = options.child,
        hover_background = options.hover_background,
        pressed_background = options.pressed_background,
        focused_border = options.focused_border,
        focused_border_width = options.focused_border_width,
        cursor = options.cursor,
        activation = options.activation,
        on_tap = options.on_tap,
        on_tap_down = options.on_tap_down,
        on_tap_up = options.on_tap_up,
        on_tap_cancel = options.on_tap_cancel,
        on_hover = options.on_hover,
        buttons = options.buttons,
        on_scroll = options.on_scroll,
    }
end

--- Composable press primitive: hover/pressed backgrounds, a focused
--- border, cursor shape, and tap callbacks around any child. The child
--- should be a box/container so state backgrounds and borders have
--- somewhere to paint. A pressable with `on_tap` participates in focus
--- traversal, so Enter/Space activate it and `focused_border` marks
--- keyboard focus. Hover and press restyle in place without rebuilding
--- the app. `on_hover(hovered)` fires on pointer enter/leave, driven only
--- by real pointer motion (content scrolling beneath a stationary
--- pointer does not re-fire it).
---
--- `on_tap` fires on pointer-down by default (the desktop feels
--- snappier). Pass `activation = "release"` to wait for pointer-up over
--- the same target, letting a press be aborted by dragging off before
--- letting go.
function ui.pressable(options)
    return {
        type = "gesture",
        id = options.id,
        child = options.child,
        hover_background = options.hover_background,
        pressed_background = options.pressed_background,
        focused_border = options.focused_border,
        focused_border_width = options.focused_border_width,
        cursor = options.cursor,
        activation = options.activation,
        on_tap = options.on_tap,
        on_tap_down = options.on_tap_down,
        on_tap_up = options.on_tap_up,
        on_tap_cancel = options.on_tap_cancel,
        on_hover = options.on_hover,
        buttons = options.buttons,
        on_scroll = options.on_scroll,
    }
end

--- Declares that a popup may hang off this widget's laid-out rect. The
--- child renders inline; when `popup` is set (see ui.popup) the runtime
--- realizes it as a separate surface anchored to this widget. Popup
--- existence is state-driven: builds that omit `popup` dismiss it.
function ui.anchored(options)
    return {
        type = "anchored",
        id = options.id,
        child = options.child,
        popup = options.popup,
    }
end

--- Declares one window of the app's window set, returned from the app's
--- `windows(ctx)` function. Windows are diffed by `id`: a newly declared
--- id creates a surface, a dropped id destroys it. Fields left nil
--- inherit the app-level defaults; `output` names the output a
--- layer-shell window is placed on (see ctx.outputs). A layer-shell window's
--- height may be `"content"`; its retained root child is then laid out under
--- a loose, output-capped height. Prefer natural or loose Flexible children
--- over Expanded in a shrink-wrapped direction. `on_close` fires when the
--- compositor closes the window so app state can stop declaring it.
---
--- A callable table rather than a function: the runtime attaches
--- window-level operations (start_move, start_resize,
--- request_activation_token) to it.
ui.window = setmetatable({}, {
    __call = function(_, options)
        return {
            id = options.id,
            title = options.title,
            width = options.width,
            height = options.height,
            output = options.output,
            layer_shell = options.layer_shell,
            background_blur = options.background_blur,
            on_close = options.on_close,
            child = options.child,
        }
    end,
})

--- Popup declaration for ui.anchored. `content` is a widget table, or a
--- function receiving the popup's runtime state and returning one.
--- `on_close` fires when Escape is pressed or the compositor dismisses the
--- popup (for example a click elsewhere), so app state can stop declaring it.
function ui.popup(options)
    return {
        content = options.content,
        edge = options.edge,
        alignment = options.alignment,
        gap = options.gap,
        width = options.width,
        height = options.height,
        on_close = options.on_close,
    }
end

function ui.focus(options)
    options = options or {}
    return {
        type = "focus",
        id = options.id,
        child = options.child,
        autofocus = options.autofocus or false,
        skip_traversal = options.skip_traversal or false,
        can_request_focus = options.can_request_focus ~= false,
        on_focus_change = options.on_focus_change,
    }
end

function ui.focus_scope(options)
    options = options or {}
    return {
        type = "focus_scope",
        id = options.id,
        child = options.child,
        modal = options.modal or false,
    }
end

function ui.text_input(options)
    options = options or {}
    return {
        type = "text_input",
        id = options.id,
        placeholder = options.placeholder,
        value = options.value,
        on_change = options.on_change,
        on_submit = options.on_submit,
        obscured = options.obscured or false,
        clear_on_submit = options.clear_on_submit or false,
        autofocus = options.autofocus or false,
        variant = options.variant,
        background = options.background,
        foreground = options.foreground,
        placeholder_color = options.placeholder_color,
        border = options.border,
        focused_border = options.focused_border,
        padding_x = options.padding_x,
        padding_y = options.padding_y,
        radius = options.radius,
        font_size = options.font_size,
        line_height = options.line_height,
    }
end

function ui.scroll(options)
    options = options or {}
    return {
        type = "scroll",
        id = options.id,
        child = options.child,
        axes = options.axes,
    }
end

function ui.list(options)
    options = options or {}
    return {
        type = "list",
        id = options.id,
        count = options.count,
        item_height = options.item_height,
        selected = options.selected,
        follow_end = options.follow_end,
        build_item = options.build_item,
    }
end

function ui.column(options)
    options = options or {}
    return {
        type = "column",
        children = options.children,
        spacing = options.spacing or 0,
        align = options.align,
        main_align = options.main_align,
    }
end

function ui.row(options)
    options = options or {}
    return {
        type = "row",
        children = options.children,
        spacing = options.spacing or 0,
        align = options.align,
        main_align = options.main_align,
    }
end

function ui.expanded(child, flex)
    return {
        type = "flexible",
        child = child,
        flex = flex or 1,
        fit = "tight",
    }
end

function ui.flexible(child, flex)
    return {
        type = "flexible",
        child = child,
        flex = flex or 1,
        fit = "loose",
    }
end

function ui.sized(options, child)
    options = options or {}
    if options.child then
        child = options.child
    end
    return {
        type = "sized",
        child = child,
        width = options.width,
        height = options.height,
        min_width = options.min_width,
        min_height = options.min_height,
        max_width = options.max_width,
        max_height = options.max_height,
    }
end

function ui.separator(options)
    options = options or {}
    return {
        type = "separator",
        color = options.color,
        thickness = options.thickness,
        axis = options.axis,
        margin = options.margin,
    }
end

function ui.spacer(flex)
    return {
        type = "spacer",
        flex = flex or 1,
    }
end

function ui.spinner(options)
    options = options or {}
    return {
        type = "spinner",
        size = options.size,
        color = options.color,
        period_ms = options.period_ms,
    }
end

function ui.svg_icon(options)
    options = options or {}
    return {
        type = "svg_icon",
        path = options.path,
        size = options.size,
        color = options.color,
    }
end

function ui.image(options)
    options = options or {}
    return {
        type = "image",
        path = options.path,
        width = options.width,
        height = options.height,
        size = options.size,
        format = options.format,
        pixels = options.pixels,
        fit = options.fit,
        align = options.align,
        cache = options.cache,
        revision = options.revision,
    }
end

function ui.icon(options)
    options = options or {}
    return {
        type = "icon",
        name = options.name,
        size = options.size,
        color = options.color,
        symbolic = options.symbolic,
    }
end

function ui.icon_label(icon_name, text, options)
    options = options or {}
    -- No size default here: a nil size falls through to the enclosing
    -- icon_theme context or the bridge's default.
    local children = {
        ui.icon({
            name = icon_name,
            size = options.size,
            color = options.color,
            symbolic = options.symbolic,
        }),
    }
    if text and text ~= "" then
        table.insert(
            children,
            ui.label(text, {
                color = options.color,
                size = options.label_size,
                font_size = options.font_size,
                line_height = options.line_height,
                role = options.role,
            })
        )
    end
    -- "cap_center" centers the icon on the text's cap-height midline (like
    -- macOS symbol alignment) instead of the text box's geometric center.
    return ui.row({
        spacing = options.spacing or default_theme.space[2],
        align = options.align or "cap_center",
        children = children,
    })
end

local function build_chip(options, theme)
    local chip_theme = theme and theme.components and theme.components.chip or {}
    local selected = options.selected or false
    local background = options.background or chip_theme.background
    if selected then
        background = options.selected_background or chip_theme.selected_background or background
    end
    local color = options.color or chip_theme.foreground
    if selected then
        color = options.selected_color or chip_theme.selected_foreground or color
    end
    local hover_background = options.hover_background or chip_theme.hover_background
    local pressed_background = options.pressed_background or chip_theme.pressed_background
    if selected then
        hover_background = options.selected_hover_background or chip_theme.selected_hover_background
        pressed_background = options.selected_pressed_background or chip_theme.selected_pressed_background
    end

    local padding = options.padding
    if not padding then
        padding = {
            x = chip_theme.padding_x or default_theme.components.chip.padding_x,
            y = chip_theme.padding_y or default_theme.components.chip.padding_y,
        }
    end

    local child = options.child
    if not child then
        if options.icon then
            child = ui.icon_label(options.icon, options.label, {
                size = options.icon_size or options.size or chip_theme.icon_size,
                color = color,
                label_size = options.label_size or chip_theme.font_size,
                font_size = options.font_size or chip_theme.font_size,
                line_height = options.line_height or chip_theme.line_height,
                role = options.role,
                spacing = options.spacing or chip_theme.gap,
            })
        else
            child = ui.label(options.label or "", {
                color = color,
                size = options.label_size or chip_theme.font_size,
                font_size = options.font_size or chip_theme.font_size,
                line_height = options.line_height or chip_theme.line_height,
                role = options.role,
            })
        end
    end
    return ui.gesture({
        id = options.id,
        child = ui.container({
            background = background,
            border = options.border,
            border_width = options.border_width,
            radius = options.radius or chip_theme.radius,
            min_width = options.min_width,
            min_height = options.min_height or chip_theme.min_height,
            align = options.align,
            horizontal_align = options.horizontal_align,
            vertical_align = options.vertical_align or "center",
            padding = padding,
        }, child),
        hover_background = hover_background,
        pressed_background = pressed_background,
        focused_border = options.focused_border or chip_theme.focused_border,
        focused_border_width = options.focused_border_width or chip_theme.focused_border_width,
        cursor = options.cursor,
        activation = options.activation,
        on_tap = options.on_tap,
        on_tap_down = options.on_tap_down,
        on_tap_up = options.on_tap_up,
        on_tap_cancel = options.on_tap_cancel,
    })
end

local Chip = ui.stateful({
    build = function(self, context)
        return build_chip(self.props, self.props.theme or context.theme)
    end,
})

--- Chip metrics and colors come from the ambient theme. Pass `theme` only
--- to intentionally override `theme.components.chip`; explicit style options
--- always win.
function ui.chip(options)
    return Chip(options)
end

local function build_menu(options, theme)
    local menu_theme = theme and theme.components and theme.components.menu or {}
    return ui.container({
        background = options.background or menu_theme.background,
        border = options.border or menu_theme.border,
        border_width = options.border_width or menu_theme.border_width,
        radius = options.radius or menu_theme.radius,
        shadow = options.shadow or menu_theme.shadow,
        padding = options.padding or menu_theme.padding,
        child = options.child,
    })
end

local Menu = ui.stateful({
    build = function(self, context)
        return build_menu(self.props, self.props.theme or context.theme)
    end,
})

--- Menu surface using the ambient `theme.components.menu` colors and metrics.
--- Placement remains the responsibility of ui.popup/ui.anchored.
function ui.menu(options)
    return Menu(options)
end

local function build_menu_item(options, theme)
    local menu_theme = theme and theme.components and theme.components.menu or {}
    local item_theme = menu_theme.item or {}
    local selected = options.selected or false
    local background = options.background
    local hover_background
    local pressed_background = options.pressed_background or item_theme.pressed_background
    if options.hover_background ~= false then
        hover_background = options.hover_background or item_theme.hover_background
    end
    if selected then
        background = options.selected_background or item_theme.selected_background or background
        pressed_background = options.selected_pressed_background or item_theme.selected_pressed_background
            or pressed_background
        if options.hover_background ~= false then
            if options.selected_hover_background == false then
                hover_background = nil
            else
                hover_background = options.selected_hover_background or item_theme.selected_hover_background
                    or hover_background
            end
        end
    end
    local padding = options.padding
    if not padding then
        padding = {
            x = item_theme.padding_x or default_theme.components.menu.item.padding_x,
            y = item_theme.padding_y or default_theme.components.menu.item.padding_y,
        }
    end
    local child = ui.default_text_style({
        font_size = item_theme.font_size or default_theme.components.menu.item.font_size,
        line_height = item_theme.line_height or default_theme.components.menu.item.line_height,
        child = options.child,
    })
    return ui.pressable({
        id = options.id,
        hover_background = hover_background,
        pressed_background = pressed_background,
        cursor = options.cursor,
        activation = options.activation,
        on_tap = options.on_tap,
        on_hover = options.on_hover,
        child = ui.container({
            background = background,
            radius = options.radius or item_theme.radius,
            min_height = options.min_height or item_theme.min_height,
            padding = padding,
        }, child),
    })
end

local MenuItem = ui.stateful({
    build = function(self, context)
        return build_menu_item(self.props, self.props.theme or context.theme)
    end,
})

--- Interactive row using the ambient `theme.components.menu.item` colors and
--- metrics. `selected` lets keyboard and pointer selection share one highlight.
function ui.menu_item(options)
    return MenuItem(options)
end

local function build_menu_label(options, theme)
    local menu_theme = theme and theme.components and theme.components.menu or {}
    local label_theme = menu_theme.label or {}
    local child = options.child
        or ui.label(options.text or "", {
            color = options.color or label_theme.foreground,
            font_size = label_theme.font_size or default_theme.components.menu.label.font_size,
            line_height = label_theme.line_height or default_theme.components.menu.label.line_height,
        })
    if options.child then
        child = ui.default_text_style({
            color = options.color or label_theme.foreground,
            font_size = label_theme.font_size or default_theme.components.menu.label.font_size,
            line_height = label_theme.line_height or default_theme.components.menu.label.line_height,
            child = child,
        })
    end
    local padding = options.padding
    if not padding then
        padding = {
            x = label_theme.padding_x or default_theme.components.menu.label.padding_x,
            y = label_theme.padding_y or default_theme.components.menu.label.padding_y,
        }
    end
    return ui.container({
        min_height = options.min_height or label_theme.min_height,
        padding = padding,
        child = child,
    })
end

local MenuLabel = ui.stateful({
    build = function(self, context)
        return build_menu_label(self.props, self.props.theme or context.theme)
    end,
})

--- Non-interactive menu row for a group or section name.
function ui.menu_label(options)
    return MenuLabel(options)
end

local function build_menu_separator(options, theme)
    local menu_theme = theme and theme.components and theme.components.menu or {}
    local separator_theme = menu_theme.separator or {}
    return ui.padding({
        x = options.inset or separator_theme.inset or default_theme.components.menu.separator.inset,
        child = ui.separator({
            color = options.color or separator_theme.color,
            thickness = options.thickness or separator_theme.thickness or 1,
            margin = options.margin or separator_theme.margin or default_theme.components.menu.separator.margin,
            axis = options.axis,
        }),
    })
end

local MenuSeparator = ui.stateful({
    build = function(self, context)
        return build_menu_separator(self.props, self.props.theme or context.theme)
    end,
})

--- Themed divider between menu items or groups.
function ui.menu_separator(options)
    return MenuSeparator(options)
end

function ui.icon_button(options)
    return ui.chip({
        id = options.id,
        theme = options.theme,
        icon = options.icon,
        icon_size = options.size or default_theme.space[4],
        color = options.color,
        background = options.background,
        border = options.border,
        hover_background = options.hover_background,
        pressed_background = options.pressed_background,
        focused_border = options.focused_border,
        focused_border_width = options.focused_border_width,
        selected = options.selected,
        selected_background = options.selected_background,
        selected_color = options.selected_color,
        selected_hover_background = options.selected_hover_background,
        selected_pressed_background = options.selected_pressed_background,
        padding = options.padding or { all = default_theme.space[2] },
        radius = options.radius,
        on_tap = options.on_tap,
        on_tap_down = options.on_tap_down,
        on_tap_up = options.on_tap_up,
        on_tap_cancel = options.on_tap_cancel,
    })
end

function ui.padding(options)
    options = options or {}
    return {
        type = "padding",
        all = options.all,
        x = options.x,
        y = options.y,
        left = options.left,
        right = options.right,
        top = options.top,
        bottom = options.bottom,
        insets = options.insets or options.padding,
        child = options.child,
    }
end

function ui.center(child)
    return {
        type = "center",
        child = child,
    }
end

function ui.button(options)
    options = options or {}
    return {
        type = "button",
        id = options.id,
        label = options.label,
        on_pressed = options.on_pressed,
    }
end

function ui.action_button(options)
    options = options or {}
    return {
        type = "button",
        id = options.id,
        label = options.label,
        action_id = options.action_id,
    }
end

function ui.actions(options)
    options = options or {}
    return {
        type = "actions",
        bindings = options.bindings,
        child = options.child,
    }
end

function ui.shortcuts(options)
    options = options or {}
    return {
        type = "shortcuts",
        bindings = options.bindings,
        child = options.child,
    }
end

return ui
