--- Desktop notifications over org.freedesktop.Notifications.
--- send, close, and server_info make asynchronous D-Bus calls and must be
--- called from a loop task, not from the main Lua thread. Notification
--- callbacks are dispatched from a task spawned by send.

local M = {}
local dbus = require("keywork.dbus")

local destination = "org.freedesktop.Notifications"
local path = "/org/freedesktop/Notifications"
local interface = destination

local close_reasons = {
    [1] = "expired",
    [2] = "dismissed",
    [3] = "closed",
    [4] = "undefined",
}

local urgency_values = {
    low = 0,
    normal = 1,
    critical = 2,
}

local function session_bus()
    local bus, err = dbus.session()
    if not bus then return nil, err or "session bus unavailable" end
    return bus
end

local function call(bus, member, args)
    return bus:call({
        destination = destination,
        path = path,
        interface = interface,
        member = member,
        args = args,
    })
end

local function notification_hints(opts)
    local hints = {}
    if opts.urgency ~= nil then
        local urgency = urgency_values[opts.urgency]
        assert(urgency ~= nil, "urgency must be low, normal, or critical")
        hints.urgency = dbus.variant("y", urgency)
    end
    for name, value in pairs(opts.hints or {}) do
        hints[name] = value
    end
    return dbus.array("{sv}", hints)
end

local function notification_actions(actions)
    local flattened = {}
    for _, action in ipairs(actions or {}) do
        assert(type(action.id) == "string", "action id must be a string")
        assert(type(action.label) == "string", "action label must be a string")
        flattened[#flattened + 1] = action.id
        flattened[#flattened + 1] = action.label
    end
    return dbus.array("s", flattened)
end

local function watch_notification(bus, subscription, id, opts)
    local loop = require("keywork.loop")
    loop.spawn(function()
        for signal in subscription:events() do
            local args = signal.args or {}
            if args[1] == id then
                if signal.member == "ActionInvoked" and opts.on_action then
                    opts.on_action(args[2])
                elseif signal.member == "NotificationClosed" then
                    if opts.on_close then
                        opts.on_close(close_reasons[args[2]] or "undefined")
                    end
                    subscription:cancel()
                    bus:close()
                    return
                end
            end
        end
        bus:close()
    end)
end

--- Sends a desktop notification and returns its numeric id. When callbacks
--- are requested, signal subscriptions are installed before Notify to avoid
--- missing an immediate action or close event.
function M.send(opts)
    assert(type(opts) == "table", "send requires an options table")
    assert(type(opts.summary) == "string", "send requires a summary string")
    assert(
        opts.on_action == nil or type(opts.on_action) == "function",
        "on_action must be a function"
    )
    assert(
        opts.on_close == nil or type(opts.on_close) == "function",
        "on_close must be a function"
    )

    local bus, err = session_bus()
    if not bus then return nil, err end

    local subscription
    if opts.on_action or opts.on_close then
        subscription = bus:subscribe({
            path = path,
            interface = interface,
        })
    end

    local reply
    reply, err = call(bus, "Notify", {
        dbus.string(opts.app_name or ""),
        dbus.uint32(opts.replaces_id or 0),
        dbus.string(opts.icon or ""),
        dbus.string(opts.summary),
        dbus.string(opts.body or ""),
        notification_actions(opts.actions),
        notification_hints(opts),
        dbus.int32(opts.timeout_ms == nil and -1 or opts.timeout_ms),
    })
    if not reply then
        if subscription then subscription:cancel() end
        bus:close()
        return nil, err or "notification failed"
    end

    local id = (reply.args or {})[1]
    if subscription then
        watch_notification(bus, subscription, id, opts)
    else
        bus:close()
    end
    return id
end

--- Closes a notification previously returned by send.
function M.close(id)
    assert(type(id) == "number", "close requires a notification id")
    local bus, err = session_bus()
    if not bus then return nil, err end
    local reply
    reply, err = call(bus, "CloseNotification", { dbus.uint32(id) })
    bus:close()
    if not reply then return nil, err or "failed to close notification" end
    return true
end

--- Returns the notification server's identity and protocol versions.
function M.server_info()
    local bus, err = session_bus()
    if not bus then return nil, err end
    local reply
    reply, err = call(bus, "GetServerInformation", {})
    bus:close()
    if not reply then return nil, err or "failed to get server information" end
    local args = reply.args or {}
    return {
        name = args[1],
        vendor = args[2],
        version = args[3],
        spec_version = args[4],
    }
end

return M
