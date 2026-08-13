local kw = require("keywork")

local providers = require("shell.launcher.providers")
local match = require("shell.launcher.match")
local history = require("shell.launcher.history")

local M = {}

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
    self.scope:spawn(function()
        history.bump(self.counts, entry.id)
    end)
    if self.actions_open then
        self.actions_open = false
        self:mutate()
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
    self:mutate()
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
    self:mutate()
end

local function set_query(self, text)
    self.query = text
    self.results = rank(self.entries, self.counts, text)
    self.selected = 1
    self.actions_open = false
    self:mutate()
end

local function move_selection(self, delta)
    if self.actions_open then
        local entry = self.results[self.selected]
        local count = entry and #entry.actions or 0
        if count == 0 then
            return
        end
        self.action_selected = math.max(1, math.min(count, self.action_selected + delta))
        self:mutate()
        return
    end
    local count = #self.results
    if count == 0 then
        return
    end
    self.selected = math.max(1, math.min(count, self.selected + delta))
    self:mutate()
end

local function search_field(self, theme)
    return kw.container({
        padding = { x = theme.space[4], y = theme.space[2] },
        child = kw.row({
            spacing = theme.space[2],
            align = "center",
            children = {
                kw.icon({ name = "system-search", color = theme.colors.text_tertiary }),
                kw.expanded({
                    child = kw.text_field({
                        id = "query",
                        placeholder = "Search apps…",
                        autofocus = true,
                        on_change = function(text)
                            set_query(self, text)
                        end,
                    }),
                }),
            },
        }),
    })
end

local function divider()
    return kw.separator({})
end

local function result_row(self, index, entry, command, theme)
    local selected = index == self.selected
    return kw.list_item({
        id = "result-" .. entry.id,
        title = command.title,
        leading = entry_icon(entry, theme.space[5], theme),
        trailing = kw.text(command.subtitle or "", { color = theme.colors.text_tertiary }),
        selected = selected,
        intent = command.intent,
        -- Raycast model: one highlight. Pointer hover moves the selection
        -- instead of painting a second hover state; keyboard and mouse
        -- drive the same index. Hover only fires on real pointer motion,
        -- so keyboard-driven list scrolling can't yank the selection back.
        -- While the actions menu is open the selection is pinned: moving
        -- it would silently retarget the open menu.
        on_hover = function(hovered)
            if hovered and not self.actions_open and self.selected ~= index then
                self.selected = index
                self:mutate()
            end
        end,
    })
end

local function result_list(self, entry_commands, theme)
    local row_height = theme.components.menu.item.min_height + theme.space[3]
    if #self.results == 0 then
        return kw.container({
            min_height = row_height,
            align = "center",
            child = kw.text("No matches", { color = theme.colors.text_tertiary }),
        })
    end
    -- The list follows self.selected: moving the selection scrolls it
    -- into view, wheel scrolling roams freely until the next move.
    return kw.list_view({
        id = "results",
        item_count = #self.results,
        item_extent = row_height,
        reveal_index = self.selected,
        build_item = function(index)
            local entry = self.results[index]
            return result_row(self, index, entry, entry_commands[entry].primary, theme)
        end,
    })
end

-- The actions menu for the selected entry, shown as a popup anchored to
-- the footer's actions hint. Selection mirrors the result list: one
-- highlight driven by both keyboard and pointer.
local function action_menu(self, commands)
    return kw.command_menu({
        id = "entry-actions",
        commands = commands,
        selected = self.action_selected,
        on_hover = function(_, index, hovered)
            if hovered and self.action_selected ~= index then
                self.action_selected = index
                self:mutate()
            end
        end,
    })
end

local function footer(self, entry_commands, theme)
    local hint_color = theme.colors.text_tertiary
    -- One step below the label role (font_size[2]).
    local hint_size = theme.font_size[1]
    local function hint(keys, text)
        return kw.row({
            spacing = theme.space[1],
            align = "center",
            children = {
                kw.text(keys, { color = theme.colors.text_secondary, size = hint_size }),
                kw.text(text, { color = hint_color, size = hint_size }),
            },
        })
    end
    local entry = self.results[self.selected]
    local count = #self.results
    return kw.container({
        padding = { x = theme.space[4], y = theme.space[2] },
        child = kw.row({
            spacing = theme.space[4],
            align = "center",
            children = {
                kw.text(count == 1 and "1 result" or count .. " results", { color = hint_color, size = hint_size }),
                kw.spacer(),
                hint("↑↓", "select"),
                hint("↵", "open"),
                kw.popover({
                    id = "actions-anchor",
                    anchor = hint("↹", "actions"),
                    open = self.actions_open and entry ~= nil,
                    placement = { edge = "top", alignment = "end", gap = theme.space[2] },
                    width = 260,
                    content = function()
                        local model = entry_commands[entry]
                        return kw.action_scope({
                            actions = model.actions,
                            child = action_menu(self, model.commands),
                        })
                    end,
                    -- Escape with the menu open lands here (the runtime routes
                    -- it to popups first), so it closes the menu, not the
                    -- launcher.
                    on_close = function()
                        close_actions(self)
                    end,
                }),
                hint("esc", "close"),
            },
        }),
    })
end

local function build_commands(self)
    local scoped_actions = {}
    local entry_commands = {}
    for _, entry in ipairs(self.results) do
        local commands = {}
        local actions = {}
        for index, provider_action in ipairs(entry.actions) do
            local action = kw.action({
                id = "launcher.entry." .. entry.id .. "." .. index,
                activate = function()
                    run_action(self, entry, provider_action)
                end,
            })
            table.insert(scoped_actions, action)
            table.insert(actions, action)
            table.insert(
                commands,
                kw.command({
                    id = tostring(index),
                    title = provider_action.title,
                    intent = action,
                })
            )
        end
        entry_commands[entry] = {
            primary = kw.command({
                id = entry.id,
                title = entry.title,
                subtitle = entry.subtitle,
                icon = entry.icon,
                intent = commands[1].intent,
            }),
            actions = actions,
            commands = commands,
        }
    end

    local function navigation_action(id, activate_navigation)
        local action = kw.action({ id = "launcher." .. id, activate = activate_navigation })
        table.insert(scoped_actions, action)
        return action
    end
    local navigation = {
        activate = navigation_action("activate", function()
            activate(self)
        end),
        next = navigation_action("next", function()
            move_selection(self, 1)
        end),
        previous = navigation_action("previous", function()
            move_selection(self, -1)
        end),
        actions = navigation_action("actions", function()
            toggle_actions(self)
        end),
        dismiss = navigation_action("dismiss", function()
            dismiss(self)
        end),
    }
    return scoped_actions, entry_commands, navigation
end

-- Launcher view hosted inside the shell's launcher window. The window's
-- existence is app state; props.on_dismiss asks the shell to drop it.
local Launcher = kw.component({
    hot_id = "Launcher",
    hot_version = 2,
    init = function(self)
        self.revision = kw.signal(0)
        self.counts = {}
        self.entries = {}
        self.results = {}
        self.query = ""
        self.selected = 1
        self.actions_open = false
        self.action_selected = 1
    end,

    mutate = function(self, fn)
        if fn then fn(self) end
        self.revision:update(function(value) return value + 1 end)
    end,

    start = function(self)
        self.scope:spawn(function()
            self.counts = history.load()
            self.entries = providers.load()
            self.results = rank(self.entries, self.counts, self.query)
            self.selected = math.max(1, math.min(self.selected, #self.results))
            if self.actions_open and not self.results[self.selected] then
                self.actions_open = false
                self.action_selected = 1
            end
            self:mutate()
        end)
    end,

    build = function(self, context)
        self.revision()
        local theme = context.theme
        local scoped_actions, entry_commands, navigation = build_commands(self)

        local content = kw.column({
            align = "stretch",
            children = {
                search_field(self, theme),
                divider(),
                -- Expanded so the list's viewport is the remaining window
                -- height; the visible row count derives from it.
                kw.expanded({
                    child = kw.container({
                        padding = theme.space[2],
                        child = result_list(self, entry_commands, theme),
                    }),
                }),
                divider(),
                footer(self, entry_commands, theme),
            },
        })

        return kw.action_scope({
            actions = scoped_actions,
            child = kw.shortcuts({
                bindings = {
                    enter = navigation.activate,
                    down = navigation.next,
                    up = navigation.previous,
                    tab = navigation.actions,
                    escape = navigation.dismiss,
                },
                child = kw.container({
                    background = theme.colors.surface,
                    border = theme.colors.panel_border,
                    border_width = 1,
                    radius = theme.radius[5],
                    shadow = theme.shadow[6],
                    child = content,
                }),
            }),
        })
    end,
})

M.Launcher = Launcher

return M
