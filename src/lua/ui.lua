local ui = {}
local reactive = require("keywork.reactive")

-- The authoritative built-in profile lives separately from generic theme and
-- widget mechanics so additional design profiles do not duplicate this API.
local default_theme = require("keywork.design.fluent")

local function validate(options, allowed, name)
    options = options or {}
    for key in pairs(options) do
        if not allowed[key] then
            error(("unknown %s option: %s"):format(name, tostring(key)), 3)
        end
    end
    return options
end

local ACTION_KIND = "keywork.action"
local INTENT_KIND = "keywork.intent"

local function is_action(value)
    return type(value) == "table" and value.__keywork_kind == ACTION_KIND
end

local function is_intent(value)
    return type(value) == "table" and value.__keywork_kind == INTENT_KIND
end

local function action_enabled(action)
    local enabled = action.enabled
    if type(enabled) == "function" then
        enabled = enabled()
    end
    if type(enabled) ~= "boolean" then
        error("action enabled must resolve to a boolean", 3)
    end
    return enabled
end

--- Declares an executable capability. Actions acquire meaning when installed
--- in an `action_scope`; controls and shortcuts refer to them through intents.
function ui.action(options)
    options = validate(options, { id=true, enabled=true, activate=true }, "action")
    if type(options.id) ~= "string" or options.id == "" then
        error("action requires a non-empty id", 2)
    end
    if type(options.activate) ~= "function" then
        error("action requires activate", 2)
    end
    if options.enabled ~= nil and type(options.enabled) ~= "boolean" and type(options.enabled) ~= "function" then
        error("action enabled must be a boolean or function", 2)
    end
    return {
        __keywork_kind = ACTION_KIND,
        id = options.id,
        enabled = options.enabled == nil and true or options.enabled,
        activate = options.activate,
    }
end

--- Refers to an action without executing it. Passing the action object keeps
--- its enabled state available to controls while dispatch still uses its id.
function ui.intent(value)
    if is_intent(value) then
        return value
    end
    if is_action(value) then
        return {
            __keywork_kind = INTENT_KIND,
            action = value.id,
            _action = value,
        }
    end
    if type(value) ~= "string" or value == "" then
        error("intent requires an action or non-empty action id", 2)
    end
    return {
        __keywork_kind = INTENT_KIND,
        action = value,
    }
end

local function resolve_intent(value)
    if value == nil then
        return nil, false
    end
    local intent = ui.intent(value)
    return intent, intent._action ~= nil and not action_enabled(intent._action)
end

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

local function resolve_recipe(value, colors, space, radius, key)
    if type(value) ~= "table" then
        if key and (key:find("background", 1, true) or key:find("foreground", 1, true) or
            key:find("border", 1, true) or key:find("color", 1, true) or key == "placeholder") then
            return resolve_color(value, colors)
        end
        if key == "radius" then
            return resolve_radius(value, radius)
        end
        if key == "padding_x" or key == "padding_y" or key == "gap" or
            key == "target" or key == "icon_size" then
            return resolve_space(value, space)
        end
        return value
    end
    local result = {}
    for child_key, child in pairs(value) do
        result[child_key] = resolve_recipe(child, colors, space, radius, child_key)
    end
    return result
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
            foreground = resolve_color(item.foreground, colors),
            disabled_foreground = resolve_color(item.disabled_foreground, colors),
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
        button = resolve_recipe(theme.components and theme.components.button, colors, space, radius),
        text_field = resolve_recipe(theme.components and theme.components.text_field, colors, space, radius),
        tag = resolve_recipe(theme.components and theme.components.tag, colors, space, radius),
        badge = resolve_recipe(theme.components and theme.components.badge, colors, space, radius),
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
    style = validate(style, { color=true, size=true, font_size=true, line_height=true, role=true,
        max_lines=true, overflow=true, line_break=true }, "text style")
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

function ui.keyed(key, child)
    return {
        type = "keyed",
        key = key,
        child = child,
    }
end

local hot_component_families = {}

local function native_component(spec, source)
    if spec.hot_id ~= nil then
        if type(spec.hot_id) ~= "string" or spec.hot_id == "" then
            error("component hot_id must be a non-empty string", 2)
        end
        local version = spec.hot_version or 1
        if type(version) ~= "number" or version < 1 or version % 1 ~= 0 then
            error("component hot_version must be a positive integer", 2)
        end
        source = source or "?"
        local family = source .. "\0" .. spec.hot_id .. "\0" .. tostring(version)
        local token = hot_component_families[family]
        if token == nil then
            token = {}
            hot_component_families[family] = token
        end
        spec.__hot_token = token
    elseif spec.hot_version ~= nil then
        error("component hot_version requires hot_id", 2)
    end

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

function ui.component(spec)
    local info = debug.getinfo(2, "S")
    return reactive.component(native_component, spec, info and info.source)
end

ui.signal = reactive.signal
ui.computed = reactive.computed

function ui.theme(options)
    options = validate(options, { data=true, theme=true, child=true }, "theme")
    return {
        type = "theme",
        theme = options.data or options.theme,
        child = options.child,
    }
end

function ui.default_text_style(options)
    options = validate(options, { color=true, size=true, font_size=true, line_height=true, child=true },
        "default_text_style")
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
    options = validate(options, { color=true, size=true, symbolic=true, child=true }, "icon_theme")
    return {
        type = "icon_theme",
        color = options.color,
        size = options.size,
        symbolic = options.symbolic,
        child = options.child,
    }
end

local function native_box(style, child)
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

function ui.container(options)
    options = validate(options, { child=true, padding=true, background=true, border=true, border_width=true,
        radius=true, shadow=true, min_width=true, min_height=true, align=true, horizontal_align=true,
        vertical_align=true }, "container")
    local child = options.child
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
    return native_box({
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

function ui.gesture_detector(options)
    options = validate(options, { id=true, child=true, cursor=true, buttons=true, on_pointer_down=true,
        on_pointer_up=true, on_pointer_cancel=true, on_hover=true, on_scroll=true }, "gesture_detector")
    return {
        type = "gesture",
        id = options.id,
        child = options.child,
        cursor = options.cursor,
        focusable = false,
        on_tap_down = options.on_pointer_down,
        on_tap_up = options.on_pointer_up,
        on_tap_cancel = options.on_pointer_cancel,
        on_hover = options.on_hover,
        buttons = options.buttons,
        on_scroll = options.on_scroll,
    }
end

--- Composable press primitive: hover/pressed backgrounds, a focused
--- border, cursor shape, and activation callbacks around any child. The child
--- should be a box/container so state backgrounds and borders have
--- somewhere to paint. An enabled pressable with an action participates in focus
--- traversal, so Enter/Space activate it and `focused_border` marks
--- keyboard focus. Hover and press restyle in place without rebuilding
--- the app. `on_hover(hovered)` fires on pointer enter/leave, driven only
--- by real pointer motion (content scrolling beneath a stationary
--- pointer does not re-fire it).
---
--- By default, activation waits for pointer-up over the same target. Dragging
--- outside or receiving a pointer cancellation aborts the press. Set
--- `activation = "press"` to activate immediately on pointer-down instead.
function ui.pressable(options)
    options = validate(options, { id=true, child=true, action=true, intent=true, disabled=true, hover_background=true,
        pressed_background=true, focused_border=true, focused_border_width=true, cursor=true, buttons=true,
        activation=true,
        on_activate=true, on_press_start=true, on_press_end=true, on_press_cancel=true,
        on_hover=true, on_scroll=true }, "pressable")
    if options.action ~= nil and options.intent ~= nil then
        error("pressable action and intent are mutually exclusive", 2)
    end
    local intent, action_disabled = resolve_intent(options.intent or options.action)
    local disabled = options.disabled or action_disabled
    return {
        type = "gesture",
        id = options.id,
        child = options.child,
        hover_background = options.hover_background,
        pressed_background = options.pressed_background,
        focused_border = options.focused_border,
        focused_border_width = options.focused_border_width,
        cursor = options.cursor,
        activation = options.activation or "release",
        focusable = not disabled and (options.on_activate ~= nil or intent ~= nil),
        action_id = not disabled and intent or nil,
        on_tap = not disabled and options.on_activate or nil,
        on_tap_down = options.on_press_start,
        on_tap_up = options.on_press_end,
        on_tap_cancel = options.on_press_cancel,
        on_hover = options.on_hover,
        buttons = options.buttons,
        on_scroll = options.on_scroll,
    }
end

--- Declares that a popup may hang off this widget's laid-out rect. The anchor
--- renders inline; open popovers are realized as separate surfaces. Popup
--- existence is state-driven: builds that omit `popup` dismiss it.
local function anchored(options)
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
        options = validate(options, { id=true, title=true, width=true, height=true, output=true,
            layer_shell=true, background_blur=true, on_close=true, child=true }, "window")
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

--- `content` is a widget table, or a
--- function receiving the popup's runtime state and returning one.
--- `on_close` fires when Escape is pressed or the compositor dismisses the
--- popup (for example a click elsewhere), so app state can stop declaring it.
function ui.popover(options)
    options = validate(options, { id=true, anchor=true, open=true, placement=true, width=true, height=true,
        content=true, shadow=true, on_close=true }, "popover")
    local placement = validate(options.placement, { edge=true, alignment=true, gap=true }, "popover placement")
    local content = reactive.wrap_deferred(options.content)
    if options.shadow and content then
        if type(content) == "function" then
            local builder = content
            content = function(context)
                return native_box({ shadow = options.shadow }, builder(context))
            end
        else
            content = native_box({ shadow = options.shadow }, content)
        end
    end
    return anchored({
        id = options.id,
        child = options.anchor,
        popup = options.open and {
            content = content,
            edge = placement.edge,
            alignment = placement.alignment,
            gap = placement.gap,
            width = options.width,
            height = options.height,
            on_close = options.on_close,
        } or nil,
    })
end

function ui.focus(options)
    options = validate(options, { id=true, child=true, autofocus=true, skip_traversal=true,
        can_request_focus=true, on_focus_change=true }, "focus")
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
    options = validate(options, { id=true, child=true, modal=true }, "focus_scope")
    return {
        type = "focus_scope",
        id = options.id,
        child = options.child,
        modal = options.modal or false,
    }
end

function ui.editable_text(options)
    options = validate(options, { id=true, placeholder=true, value=true, on_change=true, on_submit=true,
        obscured=true, clear_on_submit=true, autofocus=true, background=true, foreground=true,
        placeholder_color=true, border=true, focused_border=true, padding_x=true, padding_y=true,
        radius=true, font_size=true, line_height=true }, "editable_text")
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

local TextField = ui.component({
    build = function(self, context)
        local recipe = context.theme.components.text_field
        local options = copy_table(self.props)
        options.background = recipe.background
        options.foreground = recipe.foreground
        options.placeholder_color = recipe.placeholder
        options.border = recipe.border
        options.focused_border = recipe.focused_border
        options.padding_x = recipe.padding_x
        options.padding_y = recipe.padding_y
        options.radius = recipe.radius
        options.font_size = recipe.font_size
        options.line_height = recipe.line_height
        return ui.editable_text(options)
    end,
})
function ui.text_field(options)
    return TextField(validate(options, { id=true, placeholder=true, value=true, on_change=true, on_submit=true,
        obscured=true, clear_on_submit=true, autofocus=true }, "text_field"))
end

function ui.scroll_view(options)
    options = validate(options, { id=true, child=true, axes=true }, "scroll_view")
    return {
        type = "scroll",
        id = options.id,
        child = options.child,
        axes = options.axes,
    }
end

function ui.list_view(options)
    options = validate(options, { id=true, item_count=true, item_extent=true, reveal_index=true,
        follow_end=true, build_item=true }, "list_view")
    return {
        type = "list",
        id = options.id,
        count = options.item_count,
        item_height = options.item_extent,
        selected = options.reveal_index,
        follow_end = options.follow_end,
        build_item = reactive.wrap_deferred(options.build_item, true),
    }
end

function ui.column(options)
    options = validate(options, { children=true, spacing=true, align=true, main_align=true }, "column")
    return {
        type = "column",
        children = options.children,
        spacing = options.spacing or 0,
        align = options.align,
        main_align = options.main_align,
    }
end

function ui.row(options)
    options = validate(options, { children=true, spacing=true, align=true, main_align=true }, "row")
    return {
        type = "row",
        children = options.children,
        spacing = options.spacing or 0,
        align = options.align,
        main_align = options.main_align,
    }
end

function ui.expanded(options)
    options = validate(options, { child=true, flex=true }, "expanded")
    return {
        type = "flexible",
        child = options.child,
        flex = options.flex or 1,
        fit = "tight",
    }
end

function ui.flexible(options)
    options = validate(options, { child=true, flex=true }, "flexible")
    return {
        type = "flexible",
        child = options.child,
        flex = options.flex or 1,
        fit = "loose",
    }
end

function ui.sized_box(options)
    options = validate(options, { child=true, width=true, height=true, min_width=true, min_height=true,
        max_width=true, max_height=true }, "sized_box")
    return {
        type = "sized",
        child = options.child,
        width = options.width,
        height = options.height,
        min_width = options.min_width,
        min_height = options.min_height,
        max_width = options.max_width,
        max_height = options.max_height,
    }
end

function ui.separator(options)
    options = validate(options, { color=true, thickness=true, axis=true, margin=true }, "separator")
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

function ui.progress_ring(options)
    options = validate(options, { size=true, color=true, period_ms=true }, "progress_ring")
    return {
        type = "spinner",
        size = options.size,
        color = options.color,
        period_ms = options.period_ms,
    }
end

function ui.svg_icon(options)
    options = validate(options, { path=true, size=true, color=true }, "svg_icon")
    return {
        type = "svg_icon",
        path = options.path,
        size = options.size,
        color = options.color,
    }
end

function ui.image(options)
    options = validate(options, { path=true, width=true, height=true, size=true, format=true, pixels=true,
        fit=true, align=true, cache=true, revision=true }, "image")
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

ui.pixel_buffer = setmetatable({}, {
    __call = function(_, options)
        options = validate(options, { buffer=true, width=true, height=true }, "pixel_buffer")
        return {
            type = "pixel_buffer",
            buffer = options.buffer,
            width = options.width,
            height = options.height,
        }
    end,
})

function ui.icon(options)
    options = validate(options, { name=true, size=true, color=true, symbolic=true }, "icon")
    return {
        type = "icon",
        name = options.name,
        size = options.size,
        color = options.color,
        symbolic = options.symbolic,
    }
end

local function icon_label(icon_name, text, options)
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
            ui.text(text, {
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

local button_keys = {
    id = true,
    icon = true,
    label = true,
    size = true,
    appearance = true,
    tone = true,
    disabled = true,
    activation = true,
    on_activate = true,
    on_hover = true,
    action = true,
    intent = true,
}
local icon_button_keys = {
    id = true,
    icon = true,
    size = true,
    appearance = true,
    tone = true,
    disabled = true,
    activation = true,
    on_activate = true,
    on_hover = true,
    action = true,
    intent = true,
}
local toggle_button_keys = {
    id = true,
    icon = true,
    label = true,
    size = true,
    appearance = true,
    tone = true,
    selected = true,
    disabled = true,
    activation = true,
    on_activate = true,
    on_hover = true,
    action = true,
    intent = true,
}

local function build_button(options, theme)
    local recipe = theme.components.button
    local intent, action_disabled = resolve_intent(options.intent or options.action)
    local disabled = options.disabled or action_disabled
    local size = options.size or "medium"
    local appearance = options.appearance or options.default_appearance or "secondary"
    if size ~= "small" and size ~= "medium" then
        error("invalid button size: " .. tostring(size), 3)
    end
    if not recipe.appearances[appearance] then
        error("invalid button appearance: " .. tostring(appearance), 3)
    end
    local metrics = recipe.sizes[size]
    local colors = recipe.appearances[appearance]
    if options.selected then
        colors = recipe.selected
    end
    if options.tone then
        local tone = recipe.tones[options.tone]
        if not tone then
            error("invalid button tone: " .. tostring(options.tone), 3)
        end
        colors = copy_table(colors)
        if options.selected or appearance == "primary" then
            colors.background = tone.background
            colors.foreground = tone.on_background
            colors.hover_background = tone.hover_background
            colors.pressed_background = tone.pressed_background
        else
            colors.foreground = tone.foreground
        end
    end
    if disabled then
        colors = {
            background = recipe.disabled.background,
            foreground = recipe.disabled.foreground,
            hover_background = recipe.disabled.background,
            pressed_background = recipe.disabled.background,
        }
    end
    local child
    if options.icon then
        child = icon_label(options.icon, options.label, {
            size = metrics.icon_size,
            color = colors.foreground,
            font_size = metrics.font_size,
            line_height = metrics.line_height,
            role = "label",
            spacing = metrics.gap,
        })
    else
        child = ui.text(options.label or "", {
            role = "label",
            color = colors.foreground,
            font_size = metrics.font_size,
            line_height = metrics.line_height,
        })
    end
    return ui.pressable({
        id = options.id,
        intent = intent and intent.action,
        disabled = disabled,
        activation = options.activation,
        on_activate = options.on_activate,
        on_hover = options.on_hover,
        hover_background = colors.hover_background,
        pressed_background = colors.pressed_background,
        focused_border = recipe.focused_border,
        focused_border_width = 2,
        child = ui.container({
            background = colors.background,
            radius = recipe.radius,
            min_width = options.label and nil or metrics.target,
            min_height = metrics.target,
            padding = { x = options.label and metrics.padding_x or 0 },
            horizontal_align = "center",
            vertical_align = "center",
            child = child,
        }),
    })
end

local Button = ui.component({
    build = function(self, context)
        return build_button(self.props, context.theme)
    end,
})
local function button_options(options, name)
    options = validate(options, button_keys, name)
    if options.action ~= nil and options.intent ~= nil then
        error(name .. " action and intent are mutually exclusive", 3)
    end
    if (options.action ~= nil or options.intent ~= nil) and options.on_activate then
        error(name .. " intent and on_activate are mutually exclusive", 3)
    end
    return options
end
function ui.button(options)
    return Button(button_options(options, "button"))
end
function ui.icon_button(options)
    options = validate(options, icon_button_keys, "icon_button")
    if options.action ~= nil and options.intent ~= nil then
        error("icon_button action and intent are mutually exclusive", 2)
    end
    if (options.action ~= nil or options.intent ~= nil) and options.on_activate then
        error("icon_button intent and on_activate are mutually exclusive", 2)
    end
    if not options.icon then
        error("icon_button requires icon", 2)
    end
    local props = copy_table(options)
    props.default_appearance = "subtle"
    return Button(props)
end
function ui.toggle_button(options)
    options = validate(options, toggle_button_keys, "toggle_button")
    if options.action ~= nil and options.intent ~= nil then
        error("toggle_button action and intent are mutually exclusive", 2)
    end
    if (options.action ~= nil or options.intent ~= nil) and options.on_activate then
        error("toggle_button intent and on_activate are mutually exclusive", 2)
    end
    if type(options.selected) ~= "boolean" then
        error("toggle_button requires selected", 2)
    end
    local props = copy_table(options)
    props.default_appearance = "subtle"
    return Button(props)
end

local function token(options, theme, kind)
    local recipe = theme.components[kind]
    local child = options.icon and icon_label(options.icon, options.label, {
        size = recipe.icon_size,
        color = recipe.foreground,
        font_size = recipe.font_size,
        line_height = recipe.line_height,
        spacing = recipe.gap,
    }) or ui.text(options.label or "", {
        role = "label",
        color = recipe.foreground,
        font_size = recipe.font_size,
        line_height = recipe.line_height,
    })
    return ui.container({
        background = recipe.background,
        radius = recipe.radius,
        min_height = recipe.target,
        padding = { x = recipe.padding_x },
        vertical_align = "center",
        child = child,
    })
end
local Tag = ui.component({
    build = function(self, context)
        return token(self.props, context.theme, "tag")
    end,
})
local Badge = ui.component({
    build = function(self, context)
        return token(self.props, context.theme, "badge")
    end,
})
function ui.tag(options)
    return Tag(validate(options, { icon=true, label=true }, "tag"))
end
function ui.badge(options)
    return Badge(validate(options, { icon=true, label=true }, "badge"))
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

local Menu = ui.component({
    build = function(self, context)
        return build_menu(self.props, self.props.theme or context.theme)
    end,
})

--- Menu surface using the ambient `theme.components.menu` colors and metrics.
--- Use this as popover content when menu placement and dismissal are needed.
function ui.menu_surface(options)
    return Menu(validate(options, { child=true }, "menu_surface"))
end

local function build_menu_item(options, theme)
    local menu_theme = theme and theme.components and theme.components.menu or {}
    local item_theme = menu_theme.item or {}
    local intent, action_disabled = resolve_intent(options.intent or options.action)
    local disabled = options.disabled or action_disabled
    local selected = options.selected or false
    local background
    local hover_background = item_theme.hover_background
    local pressed_background = item_theme.pressed_background
    if selected then
        background = item_theme.selected_background
        pressed_background = item_theme.selected_pressed_background or pressed_background
        hover_background = item_theme.selected_hover_background or hover_background
    end
    local padding = options.padding
    if not padding then
        padding = {
            x = item_theme.padding_x or default_theme.components.menu.item.padding_x,
            y = item_theme.padding_y or default_theme.components.menu.item.padding_y,
        }
    end
    local foreground = item_theme.foreground
    if disabled then
        foreground = item_theme.disabled_foreground
    end
    local child = ui.icon_theme({
        color = foreground,
        child = ui.default_text_style({
            color = foreground,
            font_size = item_theme.font_size or default_theme.components.menu.item.font_size,
            line_height = item_theme.line_height or default_theme.components.menu.item.line_height,
            child = options.child,
        }),
    })
    return ui.pressable({
        id = options.id,
        hover_background = hover_background,
        pressed_background = pressed_background,
        disabled = disabled,
        intent = intent and intent.action,
        on_activate = options.on_activate,
        on_hover = options.on_hover,
        child = ui.container({
            background = background,
            radius = item_theme.radius,
            min_height = item_theme.min_height,
            padding = padding,
            child = child,
        }),
    })
end

local MenuItem = ui.component({
    build = function(self, context)
        return build_menu_item(self.props, self.props.theme or context.theme)
    end,
})

--- Interactive row using the ambient `theme.components.menu.item` colors and
--- metrics. `selected` lets keyboard and pointer selection share one highlight.
function ui.menu_item(options)
    options = validate(options, { id=true, child=true, selected=true, disabled=true,
        action=true, intent=true, on_activate=true, on_hover=true }, "menu_item")
    if options.action ~= nil and options.intent ~= nil then
        error("menu_item action and intent are mutually exclusive", 2)
    end
    if (options.action ~= nil or options.intent ~= nil) and options.on_activate then
        error("menu_item intent and on_activate are mutually exclusive", 2)
    end
    return MenuItem(options)
end

local function build_menu_label(options, theme)
    local menu_theme = theme and theme.components and theme.components.menu or {}
    local label_theme = menu_theme.label or {}
    local child = options.child
        or ui.text(options.text or "", {
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

local MenuLabel = ui.component({
    build = function(self, context)
        return build_menu_label(self.props, self.props.theme or context.theme)
    end,
})

--- Non-interactive menu row for a group or section name.
function ui.menu_label(options)
    return MenuLabel(validate(options, { child=true, text=true, color=true, padding=true, min_height=true },
        "menu_label"))
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

local MenuSeparator = ui.component({
    build = function(self, context)
        return build_menu_separator(self.props, self.props.theme or context.theme)
    end,
})

--- Themed divider between menu items or groups.
function ui.menu_separator(options)
    return MenuSeparator(validate(options, { inset=true, color=true, thickness=true, margin=true, axis=true },
        "menu_separator"))
end

function ui.padding(options)
    options = validate(options, { all=true, x=true, y=true, left=true, right=true, top=true, bottom=true,
        insets=true, padding=true, child=true }, "padding")
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

function ui.center(options)
    options = validate(options, { child=true }, "center")
    return {
        type = "center",
        child = options.child,
    }
end

function ui.align(options)
    options = validate(options, { alignment=true, child=true }, "align")
    return native_box({ align = options.alignment }, options.child)
end

function ui.actions(options)
    options = validate(options, { bindings=true, child=true }, "actions")
    return {
        type = "actions",
        bindings = options.bindings,
        child = options.child,
    }
end

--- Installs first-class actions for a subtree. Disabled actions remain absent
--- from native dispatch and controls receiving the action object also render
--- disabled.
function ui.action_scope(options)
    options = validate(options, { actions=true, child=true }, "action_scope")
    if type(options.actions) ~= "table" then
        error("action_scope requires actions", 2)
    end
    local bindings = {}
    local seen = {}
    for _, action in ipairs(options.actions) do
        if not is_action(action) then
            error("action_scope actions must be created with action()", 2)
        end
        if seen[action.id] then
            error("duplicate action id in action_scope: " .. action.id, 2)
        end
        seen[action.id] = true
        if action_enabled(action) then
            bindings[action.id] = action.activate
        end
    end
    return ui.actions({ bindings = bindings, child = options.child })
end

function ui.shortcuts(options)
    options = validate(options, { bindings=true, child=true }, "shortcuts")
    if type(options.bindings) ~= "table" then
        error("shortcuts requires bindings", 2)
    end
    local bindings = {}
    for key, intent in pairs(options.bindings) do
        bindings[key] = ui.intent(intent)
    end
    return {
        type = "shortcuts",
        bindings = bindings,
        child = options.child,
    }
end

return ui
