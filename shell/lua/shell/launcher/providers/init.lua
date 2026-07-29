-- Launcher result providers. Each provider exposes load() returning a
-- list of entries in this shape:
--
--   {
--     id = "app:firefox.desktop",  -- namespaced; the frecency/history key
--     title = "Firefox",
--     subtitle = "Web Browser",    -- optional, right-aligned in the row
--     icon = "firefox",            -- xdg icon name or absolute path; optional
--     icon_tint = true,            -- tint monochrome glyph icons with the theme text color
--     search = {                   -- lowercase haystacks for the matcher
--       { text = "firefox", weight = 1.0 },
--     },
--     actions = {                  -- [1] is the default (Enter / tap)
--       { title = "Open", run = function(ctx) ... end },
--     },
--   }
--
-- An action's run(ctx) owns its own async work and calls ctx.dismiss()
-- when the launcher window should close.

local M = {}

M.list = {
    require("shell.launcher.providers.apps"),
    require("shell.launcher.providers.power"),
}

-- Entries from every provider, concatenated. sort_key is the ranking
-- tiebreak so providers don't each have to precompute it.
function M.load()
    local entries = {}
    for _, provider in ipairs(M.list) do
        for _, entry in ipairs(provider.load()) do
            entry.sort_key = entry.title:lower()
            table.insert(entries, entry)
        end
    end
    return entries
end

return M
