-- Session and power actions provider. Command entries show their exact
-- argv; native actions name the service handling them.

local loop = require("keywork.loop")
local log = require("keywork.log")
local process = require("keywork.process")
local session = require("shell.session")

local M = {}

local commands = {
    {
        id = "lock",
        title = "Lock Screen",
        icon = "system-lock-screen-symbolic",
        keywords = "lock screensaver",
        argv = { "keywork-shell", "lock" },
    },
    {
        id = "suspend",
        title = "Suspend",
        -- No suspend icon in Adwaita; the moon is the GNOME suspend metaphor.
        icon = "weather-clear-night-symbolic",
        keywords = "sleep suspend",
        argv = { "systemctl", "suspend" },
    },
    {
        id = "reboot",
        title = "Restart",
        icon = "system-reboot-symbolic",
        keywords = "reboot restart",
        argv = { "systemctl", "reboot" },
    },
    {
        id = "poweroff",
        title = "Power Off",
        icon = "system-shutdown-symbolic",
        keywords = "shutdown halt poweroff",
        argv = { "systemctl", "poweroff" },
    },
    {
        id = "logout",
        title = "Log Out",
        icon = "system-log-out-symbolic",
        keywords = "logout exit session",
        subtitle = "Keywork compositor",
        action = session.logout,
    },
    {
        id = "restart-shell",
        title = "Restart Shell",
        icon = "view-refresh-symbolic",
        keywords = "keywork shell reload restart",
        argv = { "systemctl", "--user", "restart", "keywork-shell.service" },
    },
}

local function run(command, ctx)
    loop.spawn(function()
        if command.action then
            local ok, err = command.action()
            if not ok then
                log.warn("power action failed", command.id, err or "unknown")
            end
        else
            local result, err = process.capture(command.argv)
            if not result then
                log.warn("power action failed", command.argv[1], err or "unknown")
            elseif not result.ok then
                log.warn("power action failed", command.argv[1], result.stderr or "")
            end
        end
        -- Dismiss after the command finishes, mirroring the apps provider;
        -- these are all short-lived. Restart Shell never gets here — the
        -- restart tears this process down — which is fine.
        ctx.dismiss()
    end)
end

function M.load()
    local entries = {}
    for _, command in ipairs(commands) do
        table.insert(entries, {
            id = "power:" .. command.id,
            title = command.title,
            subtitle = command.subtitle or table.concat(command.argv, " "),
            icon = command.icon,
            -- These resolve to monochrome glyphs in most themes; tint them
      -- with the theme text color so they read on the highlight.
            icon_tint = true,
            search = {
                { text = command.title:lower(), weight = 1.0 },
                { text = command.keywords, weight = 0.8 },
            },
            actions = {
                {
                    title = "Run",
                    run = function(ctx)
                        run(command, ctx)
                    end,
                },
            },
        })
    end
    return entries
end

return M
