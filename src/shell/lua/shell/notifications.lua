local kw = require("keywork")
local dbus = require("keywork.dbus")
local log = require("keywork.log")
local loop = require("keywork.loop")
local xdg = require("keywork.xdg.applications")

local M = {}

local BUS_NAME = "org.freedesktop.Notifications"
local OBJECT_PATH = "/org/freedesktop/Notifications"
local INTERFACE = BUS_NAME

local CLOSE_EXPIRED = 1
local CLOSE_DISMISSED = 2
local CLOSE_BY_CALL = 3
local MAX_ID = 4294967295
local MAX_VISIBLE = 4

local retained = kw.app.hot.state("shell.notifications", {
    init = function()
        return {
            by_id = {},
            order = {},
            next_id = 1,
            generation = 0,
        }
    end,
})
---@cast retained { by_id: table<integer, ShellNotification>, order: integer[], next_id: integer, generation: integer }

M.width = 380
M.gap = 16
M.horizontal_offset = 20
M.vertical_offset = 16

local entities = {
    amp = "&",
    apos = "'",
    gt = ">",
    lt = "<",
    quot = '"',
}

local function utf8(codepoint)
    if not codepoint or codepoint < 0 or codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff) then
        return nil
    end
    if codepoint <= 0x7f then
        return string.char(codepoint)
    elseif codepoint <= 0x7ff then
        return string.char(0xc0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
    elseif codepoint <= 0xffff then
        return string.char(
            0xe0 + math.floor(codepoint / 0x1000),
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + codepoint % 0x40
        )
    end
    return string.char(
        0xf0 + math.floor(codepoint / 0x40000),
        0x80 + math.floor(codepoint / 0x1000) % 0x40,
        0x80 + math.floor(codepoint / 0x40) % 0x40,
        0x80 + codepoint % 0x40
    )
end

-- Some clients send the specification's body markup even when a server does
-- not advertise it. Strip only known markup so ordinary text such as an email
-- address in angle brackets remains intact.
local function body_text(value)
    value = tostring(value or "")
    value = value:gsub("<(%/?)([%a]+)(.-)>", function(slash, name, rest)
        local tag = name:lower()
        if tag == "br" or (tag == "p" and slash == "/") then
            return "\n"
        end
        if tag == "a" or tag == "b" or tag == "i" or tag == "img" or tag == "p" or tag == "u" then
            return ""
        end
        return "<" .. slash .. name .. rest .. ">"
    end)
    value = value:gsub("&#x([%da-fA-F]+);", function(hex)
        return utf8(tonumber(hex, 16)) or "&#x" .. hex .. ";"
    end)
    value = value:gsub("&#(%d+);", function(decimal)
        return utf8(tonumber(decimal)) or "&#" .. decimal .. ";"
    end)
    return value:gsub("&([%a]+);", function(name)
        return entities[name] or "&" .. name .. ";"
    end)
end

local function image_data(value)
    if type(value) ~= "table" then
        return nil
    end
    local width = math.floor(tonumber(value[1]) or 0)
    local height = math.floor(tonumber(value[2]) or 0)
    local rowstride = math.floor(tonumber(value[3]) or 0)
    local has_alpha = value[4] == true
    local bits_per_sample = tonumber(value[5])
    local channels = math.floor(tonumber(value[6]) or 0)
    local bytes = value[7]
    local byte_count = type(bytes) == "string" and #bytes or type(bytes) == "table" and #bytes or 0
    if width <= 0 or height <= 0 or width > 2048 or height > 2048 or width * height > 512 * 512 or bits_per_sample ~= 8
        or channels ~= (has_alpha and 4 or 3) or rowstride < width * channels
        or byte_count < (height - 1) * rowstride + width * channels then
        return nil
    end

    local function byte(index)
        local result = type(bytes) == "string" and bytes:byte(index) or tonumber(bytes[index])
        if not result or result < 0 or result > 255 or result ~= math.floor(result) then
            return nil
        end
        return result
    end

    local rows = {}
    for y = 0, height - 1 do
        local source_row = y * rowstride
        local pixels = {}
        for x = 0, width - 1 do
            local source = source_row + x * channels
            local red = byte(source + 1)
            local green = byte(source + 2)
            local blue = byte(source + 3)
            local alpha = has_alpha and byte(source + 4) or 255
            if not red or not green or not blue or not alpha then
                return nil
            end
            pixels[#pixels + 1] = string.char(alpha, red, green, blue)
        end
        rows[#rows + 1] = table.concat(pixels)
    end
    return { width = width, height = height, pixels = table.concat(rows) }
end

local function icon_value(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    if value:sub(1, 7) == "file://" then
        value = value:sub(8):gsub("%%(%x%x)", function(hex)
            return string.char(assert(tonumber(hex, 16)))
        end)
    end
    return value
end

local function notification_actions(values)
    local actions = {}
    local index = 1
    while index < #(values or {}) do
        local key = values[index]
        local label = values[index + 1]
        if type(key) == "string" and key ~= "" and type(label) == "string" then
            actions[#actions + 1] = { key = key, label = label }
        end
        index = index + 2
    end
    return actions
end

local function notification_timeout(expire_timeout, urgency)
    expire_timeout = tonumber(expire_timeout) or -1
    if expire_timeout == 0 then
        return nil
    end
    if expire_timeout > 0 then
        return expire_timeout
    end
    if urgency == 2 then
        return nil
    end
    return urgency == 0 and 4000 or 6000
end

local Server = {}
Server.__index = Server

---@class ShellNotification
---@field id             integer
---@field generation     integer
---@field timeout_ms?    number
---@field remaining_ms?  number
---@field expires_at_ms? number
---@field hovered        boolean
---@field actions        table[]
---@field resident       boolean

---@class NotificationServer
---@field bus             keywork.dbus.Bus
---@field name            keywork.dbus.OwnedName
---@field exported        keywork.dbus.ExportedObject
---@field by_id           table<integer, ShellNotification>
---@field order           integer[]
---@field next_id         integer
---@field generation      integer
---@field notifications   keywork.Signal<ShellNotification[]>
---@field closed          boolean
---@field close           fun(self: NotificationServer)
---@field notify          function
---@field remove          function
---@field schedule_expiry fun(self: NotificationServer, notification: ShellNotification)
---@field visible         fun(self: NotificationServer, limit?: integer): ShellNotification[]

function Server:changed()
    self.notifications:set(self:visible(MAX_VISIBLE))
end

function Server:emit(member, args)
    self.bus:emit({
        path = OBJECT_PATH,
        interface = INTERFACE,
        member = member,
        args = args,
    })
end

function Server:allocate_id()
    local first = self.next_id
    while true do
        local id = self.next_id
        self.next_id = id >= MAX_ID and 1 or id + 1
        retained.next_id = self.next_id
        if not self.by_id[id] then
            return id
        end
        local next_id = self.next_id
        if next_id == first then break end
    end
    error("notification id space exhausted")
end

function Server:remove(id, reason)
    local notification = self.by_id[id]
    if not notification then
        return false
    end

    self.by_id[id] = nil
    for index, existing in ipairs(self.order) do
        if existing == id then
            table.remove(self.order, index)
            break
        end
    end
    self:changed()
    self:emit("NotificationClosed", {
        dbus.uint32(id),
        dbus.uint32(reason),
    })
    return true
end

function Server:invoke(id, key, activation_token)
    local notification = self.by_id[id]
    if not notification then
        return false
    end

    local found = false
    for _, action in ipairs(notification.actions) do
        if action.key == key then
            found = true
            break
        end
    end
    if not found then
        return false
    end

    if activation_token then
        self:emit("ActivationToken", {
            dbus.uint32(id),
            dbus.string(activation_token),
        })
    end
    self:emit("ActionInvoked", {
        dbus.uint32(id),
        dbus.string(key),
    })
    if notification.resident then
        -- Resident notifications stay until the user or sender removes them;
        -- changing the generation makes an already-running expiry task stale.
        self.generation = self.generation + 1
        retained.generation = self.generation
        notification.generation = self.generation
        notification.timeout_ms = nil
        notification.remaining_ms = nil
        notification.expires_at_ms = nil
        notification.hovered = false
    else
        self:remove(id, CLOSE_DISMISSED)
    end
    return true
end

function Server:dismiss(id)
    return self:remove(id, CLOSE_DISMISSED)
end

function Server:visible(limit)
    local result = {}
    for index = 1, math.min(limit or #self.order, #self.order) do
        result[#result + 1] = self.by_id[self.order[index]]
    end
    return result
end

---@param notification ShellNotification
function Server:schedule_expiry(notification)
    local duration = notification.remaining_ms
    if not duration or notification.hovered then
        return
    end
    local id = notification.id
    local generation = notification.generation
    notification.expires_at_ms = loop.monotonic_ms() + duration
    loop.spawn(function()
        loop.sleep(duration)
        local current = self.by_id[id] --[[@as ShellNotification?]]
        if current and current.generation == generation then
            self:remove(id, CLOSE_EXPIRED)
        end
    end)
end

function Server:set_hovered(id, hovered)
    local notification = self.by_id[id]
    if not notification or not notification.timeout_ms or notification.hovered == hovered then
        return
    end

    notification.hovered = hovered
    self.generation = self.generation + 1
    retained.generation = self.generation
    notification.generation = self.generation
    if hovered then
        if notification.expires_at_ms then
            notification.remaining_ms = math.max(0, notification.expires_at_ms - loop.monotonic_ms())
            notification.expires_at_ms = nil
        end
    elseif notification.remaining_ms and notification.remaining_ms > 0 then
        self:schedule_expiry(notification)
    else
        self:remove(id, CLOSE_EXPIRED)
    end
end

function Server:notify(app_name, replaces_id, app_icon, summary, body, actions, hints, expire_timeout)
    hints = type(hints) == "table" and hints or {}
    local urgency = math.max(0, math.min(2, tonumber(hints.urgency) or 1))
    local replacement = tonumber(replaces_id) or 0
    local id = replacement ~= 0 and replacement or self:allocate_id()
    local desktop_entry = type(hints["desktop-entry"]) == "string" and hints["desktop-entry"] ~= ""
        and hints["desktop-entry"] or nil

    self.generation = self.generation + 1
    retained.generation = self.generation
    local image = image_data(hints["image-data"] or hints.image_data)
    local icon = icon_value(hints["image-path"] or hints.image_path) or icon_value(app_icon)
    if not image and not icon then
        image = image_data(hints.icon_data)
    end
    if not image and not icon then
        local app = desktop_entry and xdg.lookup(desktop_entry) or nil
        icon = icon_value(app and app.icon) or icon_value(desktop_entry)
    end
    local notification = {
        id = id,
        app_name = tostring(app_name ~= "" and app_name or hints["desktop-entry"] or "Notification"),
        icon = icon,
        image = image,
        desktop_entry = desktop_entry,
        summary = tostring(summary or ""),
        body = body_text(body),
        actions = notification_actions(actions),
        urgency = urgency,
        resident = hints.resident == true,
        timeout_ms = notification_timeout(expire_timeout, urgency),
        generation = self.generation,
        hovered = false,
    }
    notification.remaining_ms = notification.timeout_ms

    if not self.by_id[id] then
        table.insert(self.order, 1, id)
    end
    self.by_id[id] = notification
    self:changed()
    self:schedule_expiry(notification)
    return id
end

function Server:close()
    ---@diagnostic disable-next-line: unnecessary-if
    if self.closed then return end
    self.closed = true
    local now = loop.monotonic_ms()
    for _, notification in pairs(self.by_id) do
        if notification.expires_at_ms then
            notification.remaining_ms = math.max(0, notification.expires_at_ms - now)
            notification.expires_at_ms = nil
        end
    end
    self.name:release()
    self.exported:unexport()
    self.bus:close()
end

---@return NotificationServer?
function M.serve()
    local ok, bus = pcall(function()
        return dbus.session()
    end)
    if not ok or not bus then
        log.warn("notifications disabled: session dbus unavailable")
        return nil
    end

    local name_ok, name = pcall(function()
        local owned_name = bus:request_name(BUS_NAME, { replace_existing = true, do_not_queue = true })
        return owned_name
    end)
    if not name_ok or not name then
        log.warn("notifications disabled: org.freedesktop.Notifications is already owned")
        bus:close()
        return nil
    end

    ---@type NotificationServer
    local server = setmetatable({
        bus = bus,
        name = name,
        by_id = retained.by_id,
        order = retained.order,
        next_id = retained.next_id,
        generation = retained.generation,
        closed = false,
    }, Server)
    server.notifications = kw.signal(server:visible(MAX_VISIBLE))

    server.exported = bus:export(OBJECT_PATH, {
        [INTERFACE] = {
            methods = {
                GetCapabilities = {
                    in_signature = "",
                    out_signature = "as",
                    call = function()
                        return dbus.array("s", { "actions", "body", "icon-static" })
                    end,
                },
                Notify = {
                    in_signature = "susssasa{sv}i",
                    out_signature = "u",
                    call = function(_, app_name, replaces_id, app_icon, summary, body, actions, hints, expire_timeout)
                        return dbus.uint32(
                            server:notify(
                                app_name,
                                replaces_id,
                                app_icon,
                                summary,
                                body,
                                actions,
                                hints,
                                expire_timeout
                            )
                        )
                    end,
                },
                CloseNotification = {
                    in_signature = "u",
                    out_signature = "",
                    call = function(_, id)
                        assert(server:remove(id, CLOSE_BY_CALL), "notification not found")
                    end,
                },
                GetServerInformation = {
                    in_signature = "",
                    out_signature = "ssss",
                    call = function()
                        return "keywork-shell", "rockorager", "0.1.0", "1.3"
                    end,
                },
            },
            signals = {
                NotificationClosed = { signature = "uu" },
                ActionInvoked = { signature = "us" },
                ActivationToken = { signature = "us" },
            },
        },
    })

    -- Keep scalar counters synchronized with the retained container.
    retained.by_id, retained.order = server.by_id, server.order
    for _, notification in pairs(server.by_id) do
        server.generation = server.generation + 1
        notification.generation = server.generation
        notification.hovered = false
        if notification.remaining_ms and notification.remaining_ms > 0 then
            server:schedule_expiry(notification)
        elseif notification.timeout_ms then
            server:remove(notification.id, CLOSE_EXPIRED)
        end
    end
    retained.next_id, retained.generation = server.next_id, server.generation

    log.info("notifications enabled: owning org.freedesktop.Notifications")
    return server
end

local function default_action(notification)
    for _, action in ipairs(notification.actions) do
        if action.key == "default" then
            return action
        end
    end
    return nil
end

local function invoke(server, notification, action)
    local app_id = notification.desktop_entry
    if app_id then
        app_id = app_id:gsub("%.desktop$", "")
    end
    local token = kw.window.request_activation_token(app_id and { app_id = app_id } or nil)
    server:invoke(notification.id, action.key, token)
end

local function action_buttons(server, notification, on_hover)
    local buttons = {}
    for _, action in ipairs(notification.actions) do
        if action.key ~= "default" and #buttons < 3 then
            local current = action
            buttons[#buttons + 1] = kw.expanded({
                child = kw.button({
                    id = "notification-action-" .. notification.id .. "-" .. current.key,
                    label = current.label,
                    size = "small",
                    appearance = "secondary",
                    on_hover = on_hover,
                    on_activate = function()
                        invoke(server, notification, current)
                    end,
                }),
            })
        end
    end
    return buttons
end

local NotificationCard = kw.component({
    hot_id = "NotificationCard",
    hot_version = 1,
    build = function(self, context)
        local server = self.props.server
        local notification = self.props.notification
        local theme = context.theme
        local action = default_action(notification)
        local on_hover = function(hovered)
            server:set_hovered(notification.id, hovered)
        end
        local actions = action_buttons(server, notification, on_hover)
        local icon
        if notification.image then
            icon = kw.image({
                width = notification.image.width,
                height = notification.image.height,
                size = theme.space[6],
                format = "argb32",
                pixels = notification.image.pixels,
            })
        else
            local icon_name = notification.icon
            local icon_color
            if not icon_name or icon_name == "" then
                icon_name = notification.urgency == 2 and "dialog-warning" or "dialog-information"
                icon_color = notification.urgency == 2 and theme.colors.danger or theme.colors.text_secondary
            end
            icon = kw.icon({
                name = icon_name,
                size = theme.space[6],
                color = icon_color,
            })
        end

        local header = {
            kw.text(notification.app_name, {
                color = theme.colors.text_tertiary,
                size = theme.font_size[1],
                line_height = theme.line_height[1],
                max_lines = 1,
            }),
            kw.spacer(),
        }
        header[#header + 1] = kw.icon_button({
            id = "notification-close-" .. notification.id,
            icon = "window-close",
            size = "small",
            appearance = "subtle",
            on_hover = on_hover,
            on_activate = function()
                server:dismiss(notification.id)
            end,
        })

        local text_children = {
            kw.row({
                align = "center",
                children = header,
            }),
            kw.text(notification.summary, {
                max_lines = 1,
            }),
        }
        if notification.body ~= "" then
            text_children[#text_children + 1] = kw.text(notification.body, {
                color = theme.colors.text_secondary,
                max_lines = 2,
            })
        end

        local content = kw.row({
            spacing = theme.space[3],
            children = {
                icon,
                kw.expanded({
                    child = kw.column({
                        align = "stretch",
                        spacing = theme.space[1],
                        children = text_children,
                    }),
                }),
            },
        })
        if action then
            content = kw.pressable({
                id = "notification-content-" .. notification.id,
                on_hover = on_hover,
                on_activate = function()
                    invoke(server, notification, action)
                end,
                child = content,
            })
        end

        local children = {
            content,
        }
        if #actions > 0 then
            children[#children + 1] = kw.row({
                spacing = theme.space[2],
                align = "center",
                children = actions,
            })
        end

        local card = kw.container({
            background = theme.colors.surface,
            radius = theme.radius[4],
            shadow = theme.shadow[4],
            min_width = M.width,
            padding = { x = theme.space[3], y = theme.space[2] },
            child = kw.column({
                align = "stretch",
                spacing = #actions > 0 and theme.space[2] or 0,
                children = children,
            }),
        })
        return kw.gesture_detector({
            id = "notification-hover-" .. notification.id,
            on_hover = on_hover,
            child = card,
        })
    end,
})

M.Card = NotificationCard

local NotificationStack = kw.component({
    hot_id = "NotificationStack",
    hot_version = 2,
    build = function(self)
        local children = {}
        for _, notification in ipairs(self.props.notifications) do
            children[#children + 1] = NotificationCard({
                key = "notification:" .. notification.id,
                server = self.props.server,
                notification = notification,
            })
        end
        return kw.column({
            align = "stretch",
            spacing = M.gap,
            children = children,
        })
    end,
})

M.Stack = NotificationStack

return M
