local kw = require("keywork")
local auth = require("shell.auth")
local lock = require("shell.lock")
local loop = require("keywork.loop")

local report_ready = arg[1] == "--ready"

local function pam_policy_installed()
    for _, directory in ipairs({ "/etc/pam.d/", "/usr/lib/pam.d/" }) do
        local policy = io.open(directory .. "keywork-shell", "r")
        if policy then
            policy:close()
            return true
        end
    end
    return false
end

if not pam_policy_installed() then
    io.stderr:write("keywork-shell lock: PAM policy missing; install pam/keywork-shell as /etc/pam.d/keywork-shell\n")
    os.exit(1)
end

local username = os.getenv("USER") or "User"
local status = nil

local function avatar_path()
    local home = os.getenv("HOME")
    local path = home and (home .. "/.face") or nil
    if path then
        local file = io.open(path, "rb")
        if file then
            file:close()
            return path
        end
    end
end

local user_avatar_path = avatar_path()

local function submit(password)
    if password == "" then
        status = "Enter your password"
        kw.app.invalidate()
        return
    end

    if not auth.authenticate(password) then
        status = "Authentication failed"
        kw.app.invalidate()
        return
    end

    local ok, err = kw.session_lock.unlock()
    if not ok then
        status = "Could not unlock: " .. tostring(err)
        kw.app.invalidate()
        return
    end
    kw.app.quit()
end

return kw.app({
    app_id = "dev.rockorager.keywork.Lock",
    backend = "cpu",
    session_lock = true,
    start = function()
        if not report_ready then
            return
        end
        loop.spawn(function()
            while true do
                local locked = kw.session_lock.locked()
                if locked then
                    io.stdout:write("ready\n")
                    io.stdout:flush()
                    return
                end
                loop.sleep(10)
            end
        end)
    end,
    windows = function(ctx)
        local windows = {}
        local theme = kw.theme_for(ctx)
        for index, output in ipairs(ctx.outputs) do
            -- Session lock requires a surface for every output, but only one
            -- surface should own the password input's editing state.
            local child = kw.container({ background = theme.colors.background, child = kw.spacer() })
            if index == 1 then
                child = lock.View({
                    key = "lock-view",
                    username = username,
                    avatar_path = user_avatar_path,
                    status = status,
                    on_submit = submit,
                })
            end
            windows[#windows + 1] = kw.window({
                id = "lock:" .. output.name,
                output = output.name,
                child = child,
            })
        end
        return windows
    end,
})
