local kw = require("keywork")

local providers = require("shell.launcher.providers")
local match = require("shell.launcher.match")
local history = require("shell.launcher.history")

local M = {}

local row_height = 44
local max_results = 64

M.width = 640
M.height = 470

local function rank(entries, counts, query)
    local needle = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local scored = {}
    for _, entry in ipairs(entries) do
        local score = match.score(needle, entry)
        if score then
            -- Frecency: dominates the empty-query ordering, nudges searches.
            local boost = math.min(counts[entry.id] or 0, 20)
            score = score + boost * (needle == "" and 10 or 2)
            table.insert(scored, { entry = entry, score = score })
        end
    end
    table.sort(scored, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.entry.sort_key < b.entry.sort_key
    end)
    local results = {}
    for index = 1, math.min(#scored, max_results) do
        results[index] = scored[index].entry
    end
    return results
end

local function entry_icon(entry, size, theme)
    -- kw.icon takes raw desktop-entry Icon values: theme names (with
    -- legacy stray extensions), absolute SVG/raster paths, and basename
    -- fallback for unsupported formats are handled engine-side.
    local name = entry.icon
    if not name or name == "" then
        name = "application-x-executable"
    end
    -- Tinted entries use the secondary text color; icon lookup still
    -- prefers the exact desktop icon before its symbolic fallback.
    local color = entry.icon_tint and theme.colors.text_secondary or nil
    return kw.icon({
        name = name,
        size = size,
        color = color,
    })
end

local function dismiss(self)
    if self.props.on_dismiss then
        self.props.on_dismiss()
    end
end

-- Runs one of an entry's actions. The action owns its async work and
-- dismisses the launcher through ctx when it's done.
local function run_action(self, entry, action)
    if not entry or not action then
        return
    end
    history.bump(self.counts, entry.id)
    if self.actions_open then
        self.actions_open = false
        self:set_state()
    end
    action.run({
        dismiss = function()
            dismiss(self)
        end,
    })
end

local function activate(self)
    local entry = self.results[self.selected]
    if not entry then
        return
    end
    local index = self.actions_open and self.action_selected or 1
    run_action(self, entry, entry.actions[index])
end

local function close_actions(self)
    self.actions_open = false
    self:set_state()
end

local function toggle_actions(self)
    if self.actions_open then
        close_actions(self)
        return
    end
    if not self.results[self.selected] then
        return
    end
    self.actions_open = true
    self.action_selected = 1
    self:set_state()
end

local function set_query(self, text)
    self.query = text
    self.results = rank(self.entries, self.counts, text)
    self.selected = 1
    self.actions_open = false
    self:set_state()
end

local function move_selection(self, delta)
    if self.actions_open then
        local entry = self.results[self.selected]
        local count = entry and #entry.actions or 0
        if count == 0 then
            return
        end
        self.action_selected = math.max(1, math.min(count, self.action_selected + delta))
        self:set_state()
        return
    end
    local count = #self.results
    if count == 0 then
        return
    end
    self.selected = math.max(1, math.min(count, self.selected + delta))
    self:set_state()
end

local function search_field(self, theme)
    return kw.container(
        { padding = { x = theme.space[4], y = theme.space[2] } },
        kw.row({
            spacing = theme.space[2],
            align = "center",
            children = {
                kw.icon({ name = "system-search", color = theme.colors.text_tertiary }),
                kw.expanded(
                    kw.text_input({
                        id = "query",
                        placeholder = "Search apps…",
                        autofocus = true,
                        variant = "plain",
                        padding_y = theme.components.input.padding_y,
                        on_change = function(text)
                            set_query(self, text)
                        end,
                    })
                ),
            },
        })
    )
end

local function divider()
    return kw.separator({})
end

local function result_row(self, index, entry, theme)
    local selected = index == self.selected
    return kw.pressable({
        id = "result-" .. entry.id,
        -- Raycast model: one highlight. Pointer hover moves the selection
    -- instead of painting a second hover state; keyboard and mouse
    -- drive the same index. Hover only fires on real pointer motion,
    -- so keyboard-driven list scrolling can't yank the selection back.
    -- While the actions menu is open the selection is pinned: moving
    -- it would silently retarget the open menu.
        on_hover = function(hovered)
            if hovered and not self.actions_open and self.selected ~= index then
                self.selected = index
                self:set_state()
            end
        end,
        on_tap = function()
            run_action(self, entry, entry.actions[1])
        end,
        child = kw.container({
            background = selected and theme.components.menu.item.selected_background or nil,
            radius = theme.components.menu.item.radius,
            min_height = row_height,
            vertical_align = "center",
            padding = { x = theme.components.menu.item.padding_x },
        },
            kw.row({
                spacing = theme.space[3],
                align = "center",
                children = {
                    entry_icon(entry, theme.space[5], theme),
                    kw.text(entry.title),
                    kw.spacer(),
                    kw.label(entry.subtitle or "", { color = theme.colors.text_tertiary }),
                },
            })),
    })
end

local function result_list(self, theme)
    if #self.results == 0 then
        return kw.container(
            { min_height = row_height, align = "center" },
            kw.label("No matches", { color = theme.colors.text_tertiary })
        )
    end
    -- The list follows self.selected: moving the selection scrolls it
    -- into view, wheel scrolling roams freely until the next move.
    return kw.list({
        id = "results",
        count = #self.results,
        item_height = row_height,
        selected = self.selected,
        build_item = function(index)
            return result_row(self, index, self.results[index], theme)
        end,
    })
end

-- The actions menu for the selected entry, shown as a popup anchored to
-- the footer's actions hint. Selection mirrors the result list: one
-- highlight driven by both keyboard and pointer.
local function action_menu(self, entry)
    local rows = {}
    for index, action in ipairs(entry.actions) do
        local selected = index == self.action_selected
        table.insert(
            rows,
            kw.menu_item({
                id = "action-" .. index,
                selected = selected,
                hover_background = false,
                on_hover = function(hovered)
                    if hovered and self.action_selected ~= index then
                        self.action_selected = index
                        self:set_state()
                    end
                end,
                on_tap = function()
                    run_action(self, entry, action)
                end,
                child = kw.text(action.title),
            })
        )
    end
    return kw.menu({
        child = kw.column({ align = "stretch", children = rows }),
    })
end

local function footer(self, theme)
    local hint_color = theme.colors.text_tertiary
    -- One step below the label role (font_size[2]).
    local hint_size = theme.font_size[1]
    local function hint(keys, text)
        return kw.row({
            spacing = theme.space[1],
            align = "center",
            children = {
                kw.label(keys, { color = theme.colors.text_secondary, size = hint_size }),
                kw.label(text, { color = hint_color, size = hint_size }),
            },
        })
    end
    local entry = self.results[self.selected]
    local count = #self.results
    return kw.container(
        { padding = { x = theme.space[4], y = theme.space[2] } },
        kw.row({
            spacing = theme.space[4],
            align = "center",
            children = {
                kw.label(count == 1 and "1 result" or count .. " results", { color = hint_color, size = hint_size }),
                kw.spacer(),
                hint("↑↓", "select"),
                hint("↵", "open"),
                kw.anchored({
                    id = "actions-anchor",
                    popup = (self.actions_open and entry)
                        and kw.popup({
                            shadow = theme.components.menu.shadow,
                            edge = "top",
                            alignment = "end",
                            gap = theme.space[2],
                            width = 260,
                            content = function()
                                return action_menu(self, entry)
                            end,
                            -- Escape with the menu open lands here (the runtime routes
            -- it to popups first), so it closes the menu, not the
            -- launcher.
                            on_close = function()
                                close_actions(self)
                            end,
                        }) or nil,
                    child = hint("↹", "actions"),
                }),
                hint("esc", "close"),
            },
        })
    )
end

-- Launcher view hosted inside the shell's launcher window. The window's
-- existence is app state; props.on_dismiss asks the shell to drop it.
local Launcher = kw.stateful({
    init = function(self)
        self.entries = providers.load()
        self.counts = history.load()
        self.query = ""
        self.selected = 1
        self.results = rank(self.entries, self.counts, "")
        self.actions_open = false
        self.action_selected = 1
    end,

    build = function(self, context)
        local theme = context.theme

        local content = kw.column({
            align = "stretch",
            children = {
                search_field(self, theme),
                divider(),
                -- Expanded so the list's viewport is the remaining window
        -- height; the visible row count derives from it.
                kw.expanded(kw.container({ padding = theme.space[2] }, result_list(self, theme))),
                divider(),
                footer(self, theme),
            },
        })

        return kw.actions({
            bindings = {
                activate = function()
                    activate(self)
                end,
                next = function()
                    move_selection(self, 1)
                end,
                previous = function()
                    move_selection(self, -1)
                end,
                actions = function()
                    toggle_actions(self)
                end,
                dismiss = function()
                    dismiss(self)
                end,
            },
            child = kw.shortcuts({
                bindings = {
                    enter = "activate",
                    down = "next",
                    up = "previous",
                    tab = "actions",
                    escape = "dismiss",
                },
                child = kw.box({
                    background = theme.colors.surface,
                    radius = theme.radius[4],
                }, content),
            }),
        })
    end,
})

M.Launcher = Launcher

return M
