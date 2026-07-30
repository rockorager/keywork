local kw = require("keywork")
local dbus = require("keywork.dbus")
local log = require("keywork.log")
local loop = require("keywork.loop")

local SNI_WATCHER = "org.kde.StatusNotifierWatcher"
local SNI_WATCHER_PATH = "/StatusNotifierWatcher"
local SNI_ITEM = "org.kde.StatusNotifierItem"
local DBUS_MENU = "com.canonical.dbusmenu"

local function pointer_coordinates(event)
    return math.floor(tonumber(event and (event.window_x or event.x)) or 0),
        math.floor(tonumber(event and (event.window_y or event.y)) or 0)
end

local function menu_path(item)
    local path = item and item.menu
    if type(path) == "string" and path:sub(1, 1) == "/" and path ~= "/" then
        return path
    end
    return nil
end

local function decode_menu_layout(layout)
    if type(layout) ~= "table" then
        return nil
    end
    local node = {
        id = math.floor(tonumber(layout[1]) or 0),
        props = type(layout[2]) == "table" and layout[2] or {},
        children = {},
    }
    for _, child in ipairs(type(layout[3]) == "table" and layout[3] or {}) do
        local decoded = decode_menu_layout(child)
        if decoded then
            node.children[#node.children + 1] = decoded
        end
    end
    return node
end

local function menu_label(label)
    label = tostring(label or "")
    local result = {}
    local index = 1
    while index <= #label do
        if label:sub(index, index) == "_" then
            if label:sub(index + 1, index + 1) == "_" then
                result[#result + 1] = "_"
                index = index + 2
            else
                index = index + 1
            end
        else
            result[#result + 1] = label:sub(index, index)
            index = index + 1
        end
    end
    return table.concat(result)
end

local shortcut_names = {
    Control = "Ctrl",
    Alt = "Alt",
    Shift = "Shift",
    Super = "Super",
    [" "] = "Space",
}

local function menu_shortcut(shortcuts)
    local shortcut = type(shortcuts) == "table" and shortcuts[1] or nil
    if type(shortcut) ~= "table" then
        return nil
    end
    local parts = {}
    for _, part in ipairs(shortcut) do
        parts[#parts + 1] = shortcut_names[part] or tostring(part)
    end
    return #parts > 0 and table.concat(parts, "+") or nil
end

local function canonical_tray_item(sender, service_or_path)
    service_or_path = tostring(service_or_path or "")
    if service_or_path == "" then
        return nil
    end
    if service_or_path:sub(1, 1) == "/" then
        return sender .. service_or_path, sender, service_or_path
    end
    local slash = service_or_path:find("/", 1, true)
    if slash then
        local service = service_or_path:sub(1, slash - 1)
        local path = service_or_path:sub(slash)
        return service .. path, service, path
    end
    return service_or_path .. "/StatusNotifierItem", service_or_path, "/StatusNotifierItem"
end

local function best_icon_pixmap(pixmaps)
    local best = nil
    local best_area = -1
    for _, pixmap in ipairs(pixmaps or {}) do
        local width = math.floor(tonumber(pixmap[1]) or 0)
        local height = math.floor(tonumber(pixmap[2]) or 0)
        local pixels = pixmap[3]
        local area = width * height
        if width > 0 and height > 0 and pixels and area > best_area then
            best = { width = width, height = height, pixels = pixels }
            best_area = area
        end
    end
    return best
end

local function create_tray_host(on_change)
    local ok, bus = pcall(function()
        return dbus.session()
    end)
    if not ok or not bus then
        log.warn("tray disabled: session dbus unavailable")
        return nil
    end

    ---@class TrayHost
    ---@field bus                keywork.dbus.Bus
    ---@field items              table<string, table?>
    ---@field item_order         string[]
    ---@field host_registered    boolean
    ---@field on_change?         function
    ---@field name?              keywork.dbus.OwnedName
    ---@field exported?          keywork.dbus.ExportedObject
    ---@field emit               function
    ---@field changed            function
    ---@field remove_item        function
    ---@field register_item      function
    ---@field item_ids           function
    ---@field visible_items      function
    ---@field activate           function
    ---@field secondary_activate function
    ---@field context_menu       function
    ---@field read_menu          function
    ---@field menu_event         function
    ---@field close              function
    ---@field closed             boolean
    ---@type TrayHost
    -- Methods are attached immediately below; EmmyLua 0.24 checks this table before those assignments.
    ---@diagnostic disable-next-line: missing-fields
    local host = {
        bus = bus,
        items = {},
        item_order = {},
        host_registered = true,
        on_change = on_change,
        closed = false,
    }

    function host:emit(member, id)
        self.bus:emit({
            path = SNI_WATCHER_PATH,
            interface = SNI_WATCHER,
            member = member,
            args = id and { dbus.string(id) } or {},
        })
    end

    function host:changed()
        if self.on_change then
            self.on_change()
        end
    end

    function host:remove_item(id)
        local item = self.items[id]
        if not item then
            return
        end
        log.info("tray item unregistered", id)
        if item.signal_sub then
            item.signal_sub:cancel()
        end
        if item.observer then
            item.observer:cancel()
        end
        self.items[id] = nil
        for index, existing in ipairs(self.item_order) do
            if existing == id then
                table.remove(self.item_order, index)
                break
            end
        end
        self:emit("StatusNotifierItemUnregistered", id)
        self:changed()
    end

    function host:register_item(sender, service_or_path)
        local id, service, path = canonical_tray_item(sender, service_or_path)
        if not id then
            return
        end
        if self.items[id] then
            self.items[id].observer:refresh()
            return
        end
        log.info("tray item registered", id)
        local item = {
            id = id,
            service = service,
            path = path,
            status = "Active",
        }
        self.items[id] = item
        table.insert(self.item_order, id)

        -- The observer owns the snapshot, PropertiesChanged merge, and owner
        -- tracking; the item is removed when its service leaves the bus.
        item.observer = self.bus:observe({
            destination = service,
            path = path,
            interface = SNI_ITEM,
            timeout_ms = 1000,
        })
        loop.spawn(function()
            for event in item.observer:changes() do
                if not event.available then
                    self:remove_item(item.id)
                    return
                end
                local props = event.props
                item.category = props.Category
                item.title = props.Title
                item.status = props.Status or "Active"
                item.icon_name = props.IconName
                item.icon_pixmap = props.IconPixmap
                item.tooltip = props.ToolTip
                item.menu = props.Menu
                item.item_is_menu = props.ItemIsMenu == true
                self:changed()
            end
        end)

        -- StatusNotifierItems announce changes with custom signals rather
        -- than PropertiesChanged; each one forces a fresh snapshot.
        item.signal_sub = self.bus:subscribe({
            sender = service,
            path = path,
            interface = SNI_ITEM,
        })
        loop.spawn(function()
            for signal in item.signal_sub:events() do
                if signal.member == "NewTitle" or signal.member == "NewIcon" or signal.member == "NewAttentionIcon"
                    or signal.member == "NewOverlayIcon" or signal.member == "NewToolTip"
                    or signal.member == "NewStatus" or signal.member == "NewMenu" then
                    item.observer:refresh()
                end
            end
        end)

        self:emit("StatusNotifierItemRegistered", id)
        self:changed()
    end

    function host:item_ids()
        local result = {}
        for _, id in ipairs(self.item_order) do
            table.insert(result, id)
        end
        return result
    end

    function host:visible_items()
        local result = {}
        for _, id in ipairs(self.item_order) do
            local item = self.items[id]
            if item and item.status ~= "Passive" then
                table.insert(result, item)
            end
        end
        return result
    end

    local function item_method(self, item, member, event)
        loop.spawn(function()
            local x, y = pointer_coordinates(event)
            local reply, err = self.bus:call({
                destination = item.service,
                path = item.path,
                interface = SNI_ITEM,
                member = member,
                args = { dbus.int32(x), dbus.int32(y) },
                timeout_ms = 1000,
            })
            if not reply then
                log.warn("tray item " .. member .. " failed", item.id, err or "unknown")
            end
        end)
    end

    function host:activate(item, event)
        item_method(self, item, "Activate", event)
    end

    function host:secondary_activate(item, event)
        item_method(self, item, "SecondaryActivate", event)
    end

    function host:context_menu(item, event)
        item_method(self, item, "ContextMenu", event)
    end

    function host:read_menu(item, parent_id)
        local path = menu_path(item)
        if not path then
            return nil, "item has no menu"
        end
        -- AboutToShow gives dynamic menus a chance to update before the
        -- snapshot. Older implementations may not provide it, so its result
        -- is intentionally best-effort.
        self.bus:call({
            destination = item.service,
            path = path,
            interface = DBUS_MENU,
            member = "AboutToShow",
            args = { dbus.int32(parent_id) },
            timeout_ms = 1000,
        })
        local reply, err = self.bus:call({
            destination = item.service,
            path = path,
            interface = DBUS_MENU,
            member = "GetLayout",
            args = {
                dbus.int32(parent_id),
                dbus.int32(-1),
                dbus.array("s", {}),
            },
            timeout_ms = 1000,
        })
        if not reply then
            return nil, err or "unknown"
        end
        local layout = decode_menu_layout((reply.args or {})[2])
        if not layout then
            return nil, "invalid menu layout"
        end
        return layout
    end

    function host:menu_event(item, id, name)
        local path = menu_path(item)
        if not path then
            return
        end
        loop.spawn(function()
            local reply, err = self.bus:call({
                destination = item.service,
                path = path,
                interface = DBUS_MENU,
                member = "Event",
                args = {
                    dbus.int32(id),
                    dbus.string(name),
                    dbus.variant("i", 0),
                    dbus.uint32(0),
                },
                timeout_ms = 1000,
            })
            if not reply then
                log.warn("tray menu event failed", item.id, name, err or "unknown")
            end
        end)
    end

    function host:close()
        if self.closed then return end
        self.closed = true
        for _, id in ipairs({ unpack(self.item_order) }) do
            self:remove_item(id)
        end
        if self.name then self.name:release() end
        if self.exported then self.exported:unexport() end
        self.bus:close()
    end

    local name_ok, name = pcall(function()
        local owned_name = bus:request_name(SNI_WATCHER, { replace_existing = true, do_not_queue = true })
        return owned_name
    end)
    if not name_ok or not name then
        log.warn("tray disabled: org.kde.StatusNotifierWatcher is already owned")
        bus:close()
        return nil
    end
    log.info("tray enabled: owning org.kde.StatusNotifierWatcher")
    host.name = name
    host.exported = bus:export(SNI_WATCHER_PATH, {
        [SNI_WATCHER] = {
            methods = {
                RegisterStatusNotifierItem = {
                    in_signature = "s",
                    call = function(call, service_or_path)
                        host:register_item(call.sender, service_or_path)
                    end,
                },
                RegisterStatusNotifierHost = {
                    in_signature = "s",
                    call = function()
                        host.host_registered = true
                    end,
                },
            },
            properties = {
                RegisteredStatusNotifierItems = {
                    signature = "as",
                    access = "read",
                    get = function()
                        return dbus.array("s", host:item_ids())
                    end,
                },
                IsStatusNotifierHostRegistered = {
                    signature = "b",
                    access = "read",
                    get = function()
                        return dbus.boolean(host.host_registered)
                    end,
                },
                ProtocolVersion = {
                    signature = "i",
                    access = "read",
                    get = function()
                        return dbus.int32(0)
                    end,
                },
            },
            signals = {
                StatusNotifierItemRegistered = { signature = "s" },
                StatusNotifierItemUnregistered = { signature = "s" },
                StatusNotifierHostRegistered = { signature = "" },
            },
        },
    })

    host:emit("StatusNotifierHostRegistered")
    return host
end

local TrayItems = kw.stateful({
    hot_id = "TrayItems",
    hot_version = 1,
    init = function(self)
        self.menu_generation = 0
        self.menu_pages = {}
    end,

    start = function(self)
        if self.host then self.host:close() end
        self.menu_generation = self.menu_generation + 1
        self.menu_item = nil
        self.menu_pages = {}
        self.menu_open = false
        self.menu_loading = false
        self.host = create_tray_host(function()
            ---@diagnostic disable-next-line: unnecessary-if
            if self.menu_item
                and (self.host.items[self.menu_item.id] ~= self.menu_item or self.menu_item.status == "Passive") then
                self.menu_generation = self.menu_generation + 1
                self.menu_item = nil
                self.menu_pages = {}
                self.menu_open = false
                self.menu_loading = false
            end
            self:set_state()
        end)
    end,

    dispose = function(self)
        self.menu_generation = self.menu_generation + 1
        if self.host then
            self.host:close()
        end
    end,

    close_menu = function(self)
        self.menu_generation = self.menu_generation + 1
        if self.menu_item then
            for index = #self.menu_pages, 2, -1 do
                self.host:menu_event(self.menu_item, self.menu_pages[index].id, "closed")
            end
        end
        self.menu_item = nil
        self.menu_pages = {}
        self.menu_open = false
        self.menu_loading = false
        self:set_state()
    end,

    open_menu = function(self, item, event)
        if not menu_path(item) then
            self.host:context_menu(item, event)
            return
        end
        if self.menu_open and self.menu_item == item then
            self:close_menu()
            return
        end

        self.menu_generation = self.menu_generation + 1
        local generation = self.menu_generation
        self.menu_item = item
        self.menu_pages = {}
        self.menu_open = true
        self.menu_loading = true
        self:set_state()
        loop.spawn(function()
            local root, err = self.host:read_menu(item, 0)
            if generation ~= self.menu_generation then
                return
            end
            if not root then
                log.warn("tray menu GetLayout failed", item.id, err or "unknown")
                self:close_menu()
                self.host:context_menu(item, event)
                return
            end
            self.menu_pages = { root }
            self.menu_loading = false
            self:set_state()
        end)
    end,

    open_submenu = function(self, node)
        local item = self.menu_item
        if not item or self.menu_loading then
            return
        end
        local generation = self.menu_generation
        self.menu_loading = true
        self:set_state()
        self.host:menu_event(item, node.id, "opened")
        loop.spawn(function()
            local page, err = self.host:read_menu(item, node.id)
            if generation ~= self.menu_generation then
                return
            end
            self.menu_loading = false
            if not page then
                log.warn("tray submenu GetLayout failed", item.id, err or "unknown")
                self:set_state()
                return
            end
            self.menu_pages[#self.menu_pages + 1] = page
            self:set_state()
        end)
    end,

    close_submenu = function(self)
        if #self.menu_pages <= 1 then
            return
        end
        local page = table.remove(self.menu_pages)
        self.host:menu_event(self.menu_item, page.id, "closed")
        self:set_state()
    end,

    activate_menu_item = function(self, node)
        local item = self.menu_item
        if not item then
            return
        end
        if node.props["children-display"] == "submenu" or #node.children > 0 then
            self:open_submenu(node)
            return
        end
        self.host:menu_event(item, node.id, "clicked")
        self:close_menu()
    end,

    build = function(self)
        if not self.host then
            return kw.row({ spacing = 0, children = {} })
        end

        local palette = self.props.colors
        local items = {}
        for _, item in ipairs(self.host:visible_items()) do
            local icon_name = item.icon_name or "application-x-executable"
            local pixmap = best_icon_pixmap(item.icon_pixmap)
            local icon = pixmap
                and kw.image({
                    width = pixmap.width,
                    height = pixmap.height,
                    size = 20,
                    format = "argb32",
                    pixels = pixmap.pixels,
                })
                or kw.icon({ name = icon_name, size = 20, color = palette.foreground })
            local anchor = kw.pressable({
                id = "tray-" .. item.id,
                buttons = { "left", "right", "middle" },
                on_activate = function(event)
                    if event.button == "right" then
                        self:open_menu(item, event)
                    elseif event.button == "middle" then
                        self.host:secondary_activate(item, event)
                    elseif item.item_is_menu then
                        self:open_menu(item, event)
                    else
                        self.host:activate(item, event)
                    end
                end,
                child = kw.sized_box({
                    width = 32,
                    height = 32,
                    child = kw.center({ child = icon }),
                }),
            })
            table.insert(
                items,
                kw.popover({
                    id = "tray-menu-" .. item.id,
                    anchor = anchor,
                    open = self.menu_open and self.menu_item == item,
                    placement = { edge = "bottom", alignment = "end", gap = palette.space[1] },
                    width = 320,
                    content = function()
                        local rows = {}
                        if self.menu_loading then
                            rows[1] = kw.menu_label({ text = "Loading…" })
                        else
                            local page = self.menu_pages[#self.menu_pages]
                            local last_was_separator = true
                            if #self.menu_pages > 1 then
                                rows[#rows + 1] = kw.menu_item({
                                    id = "tray-menu-back-" .. item.id,
                                    on_activate = function()
                                        self:close_submenu()
                                    end,
                                    child = kw.row({
                                        spacing = palette.space[2],
                                        align = "center",
                                        children = {
                                            kw.icon({ name = "pan-start-symbolic", color = palette.muted }),
                                            kw.text("Back", { max_lines = 1 }),
                                        },
                                    }),
                                })
                                rows[#rows + 1] = kw.menu_separator({})
                            end
                            for _, node in ipairs(page and page.children or {}) do
                                local props = node.props
                                if props.visible ~= false then
                                    if props.type == "separator" then
                                        if not last_was_separator then
                                            rows[#rows + 1] = kw.menu_separator({})
                                            last_was_separator = true
                                        end
                                    else
                                        local color
                                        if props.disposition == "warning" then
                                            color = palette.warning
                                        elseif props.disposition == "alert" then
                                            color = palette.danger
                                        elseif props.disposition == "informative" then
                                            color = palette.muted
                                        end
                                        local disabled = props.enabled == false
                                        local leading_icon = props["icon-name"]
                                        local toggle_type = props["toggle-type"]
                                        if toggle_type then
                                            if props["toggle-state"] == 1 then
                                                leading_icon = toggle_type == "radio" and "radio-checked-symbolic"
                                                    or "object-select-symbolic"
                                            elseif props["toggle-state"] == -1 then
                                                leading_icon = "checkbox-mixed-symbolic"
                                            else
                                                leading_icon = toggle_type == "radio" and "radio-symbolic"
                                                    or "checkbox-symbolic"
                                            end
                                        elseif leading_icon == "" or leading_icon == "blank-icon" then
                                            leading_icon = nil
                                        end
                                        local shortcut = menu_shortcut(props.shortcut)
                                        local submenu = props["children-display"] == "submenu" or #node.children > 0
                                        rows[#rows + 1] = kw.menu_item({
                                            id = "tray-menu-" .. item.id .. "-" .. tostring(node.id),
                                            disabled = disabled,
                                            on_activate = function()
                                                self:activate_menu_item(node)
                                            end,
                                            child = kw.row({
                                                spacing = palette.space[2],
                                                align = "center",
                                                children = {
                                                    kw.sized_box({
                                                        width = 18,
                                                        child = leading_icon
                                                            and kw.icon({
                                                                name = leading_icon,
                                                                size = 16,
                                                                color = not disabled and (color or palette.muted) or nil,
                                                            }) or kw.text(""),
                                                    }),
                                                    kw.expanded({
                                                        child = kw.text(menu_label(props.label), {
                                                            color = not disabled and color or nil,
                                                            max_lines = 1,
                                                        }),
                                                    }),
                                                    shortcut
                                                        and kw.text(shortcut, {
                                                            color = not disabled and palette.subtle or nil,
                                                            max_lines = 1,
                                                        }) or kw.text(""),
                                                    submenu
                                                        and kw.icon({
                                                            name = "pan-end-symbolic",
                                                            color = not disabled and palette.muted or nil,
                                                        }) or kw.text(""),
                                                },
                                            }),
                                        })
                                        last_was_separator = false
                                    end
                                end
                            end
                            if last_was_separator and #rows > 0 then
                                rows[#rows] = nil
                            end
                            if #rows == 0 then
                                rows[1] = kw.menu_label({ text = "No actions" })
                            end
                        end
                        return kw.menu_surface({
                            child = kw.column({ children = rows }),
                        })
                    end,
                    on_close = function()
                        self:close_menu()
                    end,
                })
            )
        end
        return kw.row({ spacing = palette.space[1], align = "center", children = items })
    end,
})

return {
    Items = TrayItems,
}
