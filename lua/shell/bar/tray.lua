local kw = require("keywork")
local dbus = require("keywork.dbus")
local log = require("keywork.log")
local loop = require("keywork.loop")

local SNI_WATCHER = "org.kde.StatusNotifierWatcher"
local SNI_WATCHER_PATH = "/StatusNotifierWatcher"
local SNI_ITEM = "org.kde.StatusNotifierItem"

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
    ---@field bus             keywork.dbus.Bus
    ---@field items           table<string, table?>
    ---@field item_order      string[]
    ---@field host_registered boolean
    ---@field on_change?      function
    ---@field name?           keywork.dbus.OwnedName
    ---@field exported?       keywork.dbus.ExportedObject
    ---@field emit            function
    ---@field changed         function
    ---@field remove_item     function
    ---@field register_item   function
    ---@field item_ids        function
    ---@field visible_items   function
    ---@field activate        function
    ---@field close           function
    ---@type TrayHost
    -- Methods are attached immediately below; EmmyLua 0.24 checks this table before those assignments.
    ---@diagnostic disable-next-line: missing-fields
    local host = {
        bus = bus,
        items = {},
        item_order = {},
        host_registered = true,
        on_change = on_change,
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
                    or signal.member == "NewStatus" then
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

    function host:activate(item)
        loop.spawn(function()
            local reply, err = self.bus:call({
                destination = item.service,
                path = item.path,
                interface = SNI_ITEM,
                member = "Activate",
                args = { dbus.int32(0), dbus.int32(0) },
                timeout_ms = 1000,
            })
            if not reply then
                log.warn("tray item Activate failed", item.id, err or "unknown")
            end
        end)
    end

    function host:close()
        for _, id in ipairs({ unpack(self.item_order) }) do
            self:remove_item(id)
        end
        if self.name then self.name:release() end
        if self.exported then self.exported:unexport() end
        self.bus:close()
    end

    local name_ok, name = pcall(function()
        return bus:request_name(SNI_WATCHER, { replace_existing = true, do_not_queue = true })
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
    init = function(self)
        self.host = create_tray_host(function()
            self:set_state()
        end)
    end,

    dispose = function(self)
        if self.host then
            self.host:close()
        end
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
            table.insert(
                items,
                kw.pressable({
                    id = "tray-" .. item.id,
                    on_activate = function()
                        self.host:activate(item)
                    end,
                    child = kw.sized_box({
                        width = 32,
                        height = 32,
                        child = kw.center({ child = icon }),
                    }),
                })
            )
        end
        return kw.row({ spacing = palette.space[1], align = "center", children = items })
    end,
})

return {
    Items = TrayItems,
}
