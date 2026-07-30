local kw = require("keywork")
local dbus = require("keywork.dbus")
local log = require("keywork.log")
local loop = require("keywork.loop")
local service = require("keywork.service")
local util = require("shell.bar.util")

local label = util.label
local status_pill = util.status_pill

local DBUS_PROPERTIES = "org.freedesktop.DBus.Properties"

local NETWORK_MANAGER = "org.freedesktop.NetworkManager"
local NETWORK_MANAGER_PATH = "/org/freedesktop/NetworkManager"
local NM_DEVICE = "org.freedesktop.NetworkManager.Device"
local NM_WIRELESS = "org.freedesktop.NetworkManager.Device.Wireless"
local NM_ACCESS_POINT = "org.freedesktop.NetworkManager.AccessPoint"
local NM_SETTINGS_CONNECTION = "org.freedesktop.NetworkManager.Settings.Connection"
local NM_DEVICE_TYPE_WIFI = 2
local NM_DEVICE_STATE_ACTIVATED = 100

local function wifi_signal_icon(percent)
    if percent >= 80 then
        return "network-wireless-signal-excellent"
    elseif percent >= 60 then
        return "network-wireless-signal-good"
    elseif percent >= 40 then
        return "network-wireless-signal-ok"
    elseif percent >= 20 then
        return "network-wireless-signal-weak"
    end
    return "network-wireless-signal-none"
end

local function pill_from_values(palette, operstate, essid, percent, on_activate)
    if not percent and operstate == "up" then
        percent = essid ~= "" and 70 or 50
    end
    percent = math.max(0, math.min(100, percent or 0))
    local name = "network-wireless-offline"
    local color = palette.error
    if operstate == "up" then
        color = palette.foreground
        name = wifi_signal_icon(percent)
    end
    return status_pill("network", name, nil, color, {
        tone = color == palette.error and "danger" or nil,
        on_activate = on_activate,
    })
end

local function wifi_menu(palette, wifi, on_select)
    wifi = wifi or {}
    on_select = on_select or function(_) end
    local rows = {}

    local header_children = { label("Wi-Fi", palette.muted), kw.spacer() }
    if wifi.status then
        table.insert(header_children, label(wifi.status, palette.subtle))
    elseif wifi.scanning then
        table.insert(header_children, label("Scanning…", palette.subtle))
    end
    table.insert(
        rows,
        kw.menu_label({
            child = kw.row({ align = "center", children = header_children }),
        })
    )

    for _, entry in ipairs(wifi.networks or {}) do
        local icon_color = entry.connected and palette.selection or palette.muted
        local text_color = entry.connected and palette.foreground or palette.muted
        local children = {
            kw.icon({ name = wifi_signal_icon(entry.percent), color = icon_color }),
            kw.expanded({ child = label(entry.name, text_color) }),
        }
        if entry.secured and not entry.known then
            table.insert(children, kw.icon({ name = "network-wireless-encrypted", color = palette.subtle }))
        end
        if entry.connected then
            table.insert(children, kw.icon({ name = "object-select", color = palette.foreground }))
        end
        table.insert(
            rows,
            kw.menu_item({
                id = "wifi-" .. entry.path,
                on_activate = function()
                    on_select(entry)
                end,
                child = kw.row({
                    spacing = palette.space[2],
                    align = "center",
                    children = children,
                }),
            })
        )
    end

    if not wifi.networks or #wifi.networks == 0 then
        table.insert(
            rows,
            kw.padding({
                x = palette.space[3],
                y = palette.space[2],
                child = label(wifi.networks and "No networks found" or "Loading…", palette.subtle),
            })
        )
    end

    return kw.menu_surface({
        child = kw.column({ children = rows }),
    })
end

local WifiMenu = kw.stateful({
    hot_id = "WifiMenu",
    hot_version = 1,
    build = function(self)
        return wifi_menu(self.props.colors, self.props.wifi, self.props.on_select)
    end,
})

local network_service = service.define("shell.bar.network", function(self)
    -- Published connection snapshot; percent stays nil until known so the
    -- pill can fall back to its optimistic guess.
    local st = { operstate = "down", essid = "", percent = nil }

    ---@type { bus: keywork.dbus.Bus?, device: string?, last_scan: number?, scanning: boolean, scan_generation: integer, refresh: function? }
    local net = { bus = nil, device = nil, last_scan = nil, scanning = false, scan_generation = 0 }
    local commands = {}

    local function publish()
        local available = net.bus ~= nil and net.device ~= nil
        self:publish({
            operstate = st.operstate,
            essid = st.essid,
            percent = st.percent,
            scan = available and commands.scan or nil,
            list = available and commands.list or nil,
            connect = available and commands.connect or nil,
        })
    end

    local function get_all(path, interface, timeout_ms)
        local reply, err = assert(net.bus):call({
            destination = NETWORK_MANAGER,
            path = path,
            interface = DBUS_PROPERTIES,
            member = "GetAll",
            args = { interface },
            timeout_ms = timeout_ms,
        })
        if not reply then
            return nil, err
        end
        return (reply.args or {})[1] or {}
    end

    -- Commands published with the snapshot. They are plain closures over the
    -- service's bus and run on the caller's task, so a disposed widget
    -- abandons its own in-flight calls.

    local function scan()
        local bus, device = net.bus, net.device
        if not bus or not device then
            return nil, "NetworkManager unavailable"
        end

        net.scanning = true
        net.scan_generation = net.scan_generation + 1
        local generation = net.scan_generation
        publish()
        local reply, err = bus:call({
            destination = NETWORK_MANAGER,
            path = device,
            interface = NM_WIRELESS,
            member = "RequestScan",
            args = { dbus.array("{sv}", {}) },
            timeout_ms = 2000,
        })
        if not reply then
            net.scanning = false
            publish()
            return nil, err
        end

        -- NetworkManager reports completion by changing LastScan. Bound the
        -- indicator in case a driver accepts the request but never completes.
        self.scope:spawn(function()
            local timer = loop.timer({ delay = 15.0 })
            for _ in timer:ticks() do
                if net.scanning and net.scan_generation == generation then
                    net.scanning = false
                    publish()
                end
            end
        end)
        return reply
    end

    -- Returns { networks, scanning } or nil on transient D-Bus failures so
    -- callers can retain their last good snapshot.
    local function list()
        local bus, device = net.bus, net.device
        if not bus or not device then
            return nil
        end

        local device_props, device_err = get_all(device, NM_DEVICE, 2000)
        if not device_props then
            log.warn("NetworkManager device properties failed", device_err or "unknown")
            return nil
        end
        local wireless_props, wireless_err = get_all(device, NM_WIRELESS, 2000)
        if not wireless_props then
            log.warn("NetworkManager wireless properties failed", wireless_err or "unknown")
            return nil
        end

        local access_points_reply, access_points_err = bus:call({
            destination = NETWORK_MANAGER,
            path = device,
            interface = NM_WIRELESS,
            member = "GetAllAccessPoints",
            timeout_ms = 3000,
        })
        if not access_points_reply then
            log.warn("NetworkManager GetAllAccessPoints failed", access_points_err or "unknown")
            return nil
        end

        -- AvailableConnections is already filtered by NetworkManager for this
        -- device. Resolve their SSIDs so known profiles can be activated
        -- directly and rendered without a lock badge.
        local known_ssids = {}
        for _, connection_path in ipairs(device_props.AvailableConnections or {}) do
            local settings_reply = bus:call({
                destination = NETWORK_MANAGER,
                path = connection_path,
                interface = NM_SETTINGS_CONNECTION,
                member = "GetSettings",
                timeout_ms = 2000,
            })
            local settings = settings_reply and ((settings_reply.args or {})[1] or {}) or nil
            local wireless = settings and settings["802-11-wireless"] or nil
            local ssid = wireless and wireless.ssid or nil
            if type(ssid) == "string" and ssid ~= "" then
                known_ssids[ssid] = true
            end
        end

        local active_path = wireless_props.ActiveAccessPoint
        local networks_by_ssid = {}
        for _, path in ipairs((access_points_reply.args or {})[1] or {}) do
            local props = get_all(path, NM_ACCESS_POINT, 2000)
            local name = props and props.Ssid or nil
            if type(name) == "string" and name ~= "" then
                local flags = tonumber(props.Flags) or 0
                local candidate = {
                    path = path,
                    name = name,
                    secured = flags % 2 == 1 or (tonumber(props.WpaFlags) or 0) ~= 0
                        or (tonumber(props.RsnFlags) or 0) ~= 0,
                    known = known_ssids[name] == true,
                    connected = path == active_path,
                    percent = math.max(0, math.min(100, tonumber(props.Strength) or 0)),
                }
                local previous = networks_by_ssid[name]
                if not previous or (candidate.connected and not previous.connected)
                    or (candidate.connected == previous.connected and candidate.percent > previous.percent) then
                    networks_by_ssid[name] = candidate
                end
            end
        end

        local networks = {}
        for _, network in pairs(networks_by_ssid) do
            table.insert(networks, network)
        end
        table.sort(networks, function(a, b)
            if a.connected ~= b.connected then
                return a.connected
            elseif a.percent ~= b.percent then
                return a.percent > b.percent
            end
            return a.name < b.name
        end)
        while #networks > 12 do
            table.remove(networks)
        end
        return { networks = networks, scanning = net.scanning }
    end

    local function connect(entry)
        local bus, device = net.bus, net.device
        if not bus or not device then
            return nil, "NetworkManager unavailable"
        end
        local reply, err
        if entry.connected then
            reply, err = bus:call({
                destination = NETWORK_MANAGER,
                path = device,
                interface = NM_DEVICE,
                member = "Disconnect",
                timeout_ms = 10000,
            })
        elseif entry.known then
            reply, err = bus:call({
                destination = NETWORK_MANAGER,
                path = NETWORK_MANAGER_PATH,
                interface = NETWORK_MANAGER,
                member = "ActivateConnection",
                args = {
                    -- Let NetworkManager select the compatible saved profile;
                    -- more than one profile may share this AP's SSID.
                    dbus.object_path("/"),
                    dbus.object_path(device),
                    dbus.object_path(entry.path),
                },
                timeout_ms = 30000,
            })
        else
            -- NetworkManager completes an empty profile from the selected AP.
            -- For secured networks it can request secrets from any registered
            -- desktop secret agent rather than making the shell own credentials.
            reply, err = bus:call({
                destination = NETWORK_MANAGER,
                path = NETWORK_MANAGER_PATH,
                interface = NETWORK_MANAGER,
                member = "AddAndActivateConnection",
                args = {
                    dbus.array("{sa{sv}}", {}),
                    dbus.object_path(device),
                    dbus.object_path(entry.path),
                },
                timeout_ms = 30000,
            })
        end
        assert(net.refresh)()
        return reply, err
    end

    commands.scan = scan
    commands.list = list
    commands.connect = connect

    local function update_network_manager_now()
        local device = net.device
        if not device then
            return
        end

        local device_props, device_err = get_all(device, NM_DEVICE, 1000)
        if not device_props then
            log.warn("NetworkManager device refresh failed", device_err or "unknown")
            return
        end
        local wireless_props, wireless_err = get_all(device, NM_WIRELESS, 1000)
        if not wireless_props then
            log.warn("NetworkManager wireless refresh failed", wireless_err or "unknown")
            return
        end

        local last_scan = tonumber(wireless_props.LastScan)
        if net.scanning and net.last_scan and last_scan and last_scan ~= net.last_scan then
            net.scanning = false
        end
        net.last_scan = last_scan

        local active_path = wireless_props.ActiveAccessPoint
        if tonumber(device_props.State) ~= NM_DEVICE_STATE_ACTIVATED or type(active_path) ~= "string"
            or active_path == "/" then
            st.operstate, st.essid, st.percent = "down", "", 0
            publish()
            return
        end

        local access_point_props, access_point_err = get_all(active_path, NM_ACCESS_POINT, 1000)
        if not access_point_props then
            log.warn("NetworkManager access point refresh failed", access_point_err or "unknown")
            return
        end
        st.operstate = "up"
        st.essid = type(access_point_props.Ssid) == "string" and access_point_props.Ssid or ""
        st.percent = math.max(0, math.min(100, tonumber(access_point_props.Strength) or 0))
        publish()
    end

    local update_running = false
    local update_pending = false
    local function update_network()
        if not net.device then
            publish()
            return
        end
        if update_running then
            update_pending = true
            return
        end
        update_running = true
        self.scope:spawn(function()
            repeat
                update_pending = false
                update_network_manager_now()
            until not update_pending
            update_running = false
        end)
    end

    net.refresh = function()
        update_network()
    end

    local discover_running = false
    local discover_pending = false
    local function discover_network_manager_now()
        local bus = assert(net.bus)
        local manager = bus:proxy(NETWORK_MANAGER, NETWORK_MANAGER_PATH, NETWORK_MANAGER, { timeout_ms = 2000 })
        local devices, err = manager:GetDevices()
        if not devices then
            log.warn("NetworkManager GetDevices failed", err or "unknown")
            net.device = nil
            st.operstate, st.essid, st.percent = "down", "", 0
            publish()
            return
        end

        for _, path in ipairs(devices) do
            local props = get_all(path, NM_DEVICE, 1000)
            if props and tonumber(props.DeviceType) == NM_DEVICE_TYPE_WIFI then
                if net.device ~= path then
                    net.device = path
                    net.last_scan = nil
                    net.scanning = false
                end
                update_network()
                return
            end
        end
        if net.device then
            net.device = nil
            net.last_scan = nil
            net.scanning = false
        end
        st.operstate, st.essid, st.percent = "down", "", 0
        publish()
    end

    local function discover_network_manager()
        if discover_running then
            discover_pending = true
            return
        end
        discover_running = true
        self.scope:spawn(function()
            repeat
                discover_pending = false
                discover_network_manager_now()
            until not discover_pending
            discover_running = false
        end)
    end

    local bus, bus_err = dbus.system()
    if not bus then
        error("system D-Bus unavailable: " .. (bus_err or "unknown"))
    end
    net.bus = bus

    local manager_observer = bus:observe({
        destination = NETWORK_MANAGER,
        path = NETWORK_MANAGER_PATH,
        interface = NETWORK_MANAGER,
        timeout_ms = 2000,
    })
    self.scope:spawn(function()
        for change in manager_observer:changes() do
            if change.available then
                if net.device then
                    update_network()
                else
                    discover_network_manager()
                end
            else
                net.device = nil
                net.last_scan = nil
                net.scanning = false
                st.operstate, st.essid, st.percent = "down", "", 0
                publish()
            end
        end
    end)

    local sub = bus:subscribe({
        path_namespace = NETWORK_MANAGER_PATH,
    })
    self.scope:spawn(function()
        for signal in sub:events() do
            if signal.member == "DeviceAdded" or signal.member == "DeviceRemoved" then
                discover_network_manager()
            elseif signal.member == "PropertiesChanged" or signal.member == "StateChanged"
                or signal.member == "AccessPointAdded" or signal.member == "AccessPointRemoved" then
                local args = signal.args or {}
                if signal.member == "PropertiesChanged" and args[1] == NM_WIRELESS then
                    local changed = args[2] or {}
                    local last_scan = tonumber(changed.LastScan)
                    if net.scanning and net.last_scan and last_scan and last_scan ~= net.last_scan then
                        net.scanning = false
                    end
                end
                update_network()
            end
        end
    end)

    publish()
    discover_network_manager()

    -- Poll as a backstop for missed device or access-point property signals.
    local timer = loop.timer({ delay = 60.0, interval = 60.0 })
    for _ in timer:ticks() do
        update_network()
    end
end)

local Network = kw.stateful({
    init = function(self)
        self.wifi_menu_open = false
    end,

    hot_id = "Network",
    hot_version = 1,
    start = function(self)
        self.wifi_refresh_pending = false --[[@as boolean]]
        self.wifi_fetching = false
        self.wifi_scan_inflight = false
        self.wifi_tap = function()
            self:toggle_wifi_menu()
        end
        self.net = network_service:use(self.scope, function(snapshot)
            self.net = snapshot
            self:set_state(function(state)
                if state.wifi_menu_open then
                    state:refresh_wifi_list()
                end
            end)
        end)
    end,

    toggle_wifi_menu = function(self)
        self:set_state(function(state)
            state.wifi_menu_open = not state.wifi_menu_open
            if state.wifi_menu_open then
                state.wifi_status = nil
                state:refresh_wifi_list()
                state:scan_wifi()
            end
        end)
    end,

    scan_wifi = function(self)
        local net = self.net
        if not net or not net.scan or self.wifi_scan_inflight then
            return
        end
        -- Show Scanning… while NetworkManager accepts the request; LastScan
        -- then keeps the service-level indicator active until completion.
        self.wifi_scan_inflight = true
        self:set_state(function(state)
            state.wifi_scanning = true
        end)
        self.scope:spawn(function()
            net.scan()
            self.wifi_scan_inflight = false
            -- Re-read so the header and list match NetworkManager's scan state.
            self:refresh_wifi_list()
        end)
    end,

    -- Coalesces concurrent refresh requests. A fetch can still be in flight
    -- when LastScan changes or an access point appears; dropping those would
    -- leave the menu stuck on a partial list until the next open.
    refresh_wifi_list = function(self)
        if self.wifi_fetching then
            self.wifi_refresh_pending = true
            return
        end
        self.wifi_fetching = true
        self.scope:spawn(function()
            while true do
                self.wifi_refresh_pending = false
                self:refresh_wifi_list_now()
                -- EmmyLua 0.24 narrows this mutable widget field from the assignment above.
                ---@diagnostic disable-next-line: unnecessary-if
                if not self.wifi_refresh_pending then
                    break
                end
            end
            self.wifi_fetching = false
        end)
    end,

    refresh_wifi_list_now = function(self)
        local net = self.net
        if not net or not net.list then
            self:set_state(function(state)
                state.wifi_status = "NetworkManager unavailable"
            end)
            return
        end
        local result = net.list()
        if not result then
            return -- retain the last good snapshot on transient D-Bus failures
        end
        self:set_state(function(state)
            state.wifi_networks = result.networks
            -- Keep Scanning… while RequestScan itself is still in flight even
            -- if this snapshot predates the service-level scan flag.
            state.wifi_scanning = result.scanning or self.wifi_scan_inflight
        end)
    end,

    connect_wifi = function(self, entry)
        local net = self.net
        if not net or not net.connect then
            return
        end
        self.scope:spawn(function()
            self:set_state(function(state)
                state.wifi_status = entry.connected and "Disconnecting…" or ("Connecting to " .. entry.name .. "…")
            end)
            local reply, err = net.connect(entry)
            self:set_state(function(state)
                state.wifi_status = reply and nil or ("Failed: " .. (err or "unknown"))
            end)
            self:refresh_wifi_list()
        end)
    end,

    build_wifi_menu = function(self)
        local palette = self.props.colors
        return wifi_menu(
            palette,
            {
                status = self.wifi_status,
                scanning = self.wifi_scanning,
                networks = self.wifi_networks,
            },
            function(entry)
                self:connect_wifi(entry)
            end
        )
    end,

    build = function(self)
        local palette = self.props.colors
        local net = self.net or { operstate = "down", essid = "", percent = 0 }
        return kw.popover({
            id = "network",
            anchor = pill_from_values(palette, net.operstate, net.essid, net.percent, self.wifi_tap),
            open = self.wifi_menu_open,
            placement = { edge = "bottom", alignment = "end", gap = palette.space[1] },
            width = 300,
            content = function()
                return self:build_wifi_menu()
            end,
            on_close = function()
                self:set_state(function(state)
                    state.wifi_menu_open = false
                end)
            end,
        })
    end,
})

return {
    Network = Network,
    Menu = WifiMenu,
}
