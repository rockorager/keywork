local kw = require("keywork")
local dbus = require("keywork.dbus")
local log = require("keywork.log")
local loop = require("keywork.loop")
local process = require("keywork.process")
local service = require("keywork.service")
local util = require("shell.bar.util")

local trim = util.trim
local label = util.label
local status_pill = util.status_pill

local DBUS_PROPERTIES = "org.freedesktop.DBus.Properties"
local DBUS_OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager"

local IWD = "net.connman.iwd"
local IWD_STATION = "net.connman.iwd.Station"
local IWD_NETWORK = "net.connman.iwd.Network"
local IWD_AGENT = "net.connman.iwd.SignalLevelAgent"
local IWD_AGENT_PATH = "/dev/keywork/bar/SignalLevelAgent"
-- dBm thresholds aligned with the 80/60/40/20 percent icon buckets.
local IWD_SIGNAL_LEVELS = { -60, -70, -80, -90 }
local IWD_LEVEL_PERCENT = { 90, 70, 50, 30, 10 }

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

local function dbm_to_percent(dbm)
    return math.max(0, math.min(100, (dbm + 100) * 2))
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

local SHELL_NETWORK_SCRIPT = [==[
iface=$(ls /sys/class/net 2>/dev/null | grep -E '^wl|^wlan' | head -n1)
if [ -z "$iface" ]; then
  printf 'down\n\n0\n'
  exit 0
fi
operstate=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || printf 'down')
essid=''
dbm=''
if command -v iw >/dev/null 2>&1; then
  link=$(iw dev "$iface" link 2>/dev/null)
  essid=$(printf '%s\n' "$link" | sed -n 's/^[[:space:]]*SSID: //p' | head -n1)
  dbm=$(printf '%s\n' "$link" | sed -n 's/^[[:space:]]*signal: \(-\{0,1\}[0-9]\{1,\}\) dBm.*/\1/p' | head -n1)
elif command -v iwctl >/dev/null 2>&1; then
  show=$(iwctl station "$iface" show 2>/dev/null)
  essid=$(printf '%s\n' "$show" | sed -n 's/^[[:space:]]*Connected network[[:space:]]*//p' | head -n1 | sed 's/[[:space:]]*$//')
  dbm=$(printf '%s\n' "$show" | sed -n 's/^[[:space:]]*RSSI[[:space:]]*\(-\{0,1\}[0-9]\{1,\}\) dBm.*/\1/p' | head -n1)
elif command -v iwgetid >/dev/null 2>&1; then
  essid=$(iwgetid -r 2>/dev/null || true)
fi
if [ -n "$dbm" ]; then
  quality=$(( (dbm + 100) * 2 ))
  [ "$quality" -gt 100 ] && quality=100
  [ "$quality" -lt 0 ] && quality=0
else
  quality=$(awk -v iface="$iface:" '$1 == iface { printf "%d", ($3 * 100 / 70 + 0.5) }' /proc/net/wireless 2>/dev/null)
fi
printf '%s\n%s\n%s\n' "$operstate" "$essid" "$quality"
]==]

local network_service = service.define("shell.bar.network", function(self)
    -- Published connection snapshot; percent stays nil until known so the
    -- pill can fall back to its optimistic guess.
    local st = { operstate = "down", essid = "", percent = nil }

    ---@type { bus: keywork.dbus.Bus?, station: string?, percent: number?, refresh: function? }
    local net = { bus = nil, station = nil, percent = nil }

    -- Commands published with the snapshot. They are plain closures over the
    -- service's bus and run on the caller's task, so a disposed widget
    -- abandons its own in-flight calls.

    local function scan()
        if not net.bus or not net.station then
            return
        end
        -- Errors here are usually "already scanning"; the results land via
        -- the Scanning PropertiesChanged signal either way.
        net.bus:call({
            destination = IWD,
            path = net.station,
            interface = IWD_STATION,
            member = "Scan",
            timeout_ms = 2000,
        })
    end

    -- Returns { networks, scanning } or nil on transient D-Bus failures so
    -- callers can retain their last good snapshot.
    local function list()
        local bus, station = net.bus, net.station
        if not bus or not station then
            return nil
        end
        local ordered_reply, ordered_err = bus:call({
            destination = IWD,
            path = station,
            interface = IWD_STATION,
            member = "GetOrderedNetworks",
            timeout_ms = 3000,
        })
        if not ordered_reply then
            log.warn("iwd GetOrderedNetworks failed", ordered_err or "unknown")
            return nil
        end
        -- Get all network metadata in one call instead of issuing a GetAll for
        -- every row. GetOrderedNetworks is still needed for order and strength.
        local managed_reply, managed_err = bus:call({
            destination = IWD,
            path = "/",
            interface = DBUS_OBJECT_MANAGER,
            member = "GetManagedObjects",
            timeout_ms = 3000,
        })
        if not managed_reply then
            log.warn("iwd GetManagedObjects failed", managed_err or "unknown")
            return nil
        end
        local scanning = false
        ---@type table<string, table?>
        local network_props = {}
        for path, interfaces in pairs((managed_reply.args or {})[1] or {}) do
            if path == station and interfaces[IWD_STATION] then
                scanning = interfaces[IWD_STATION].Scanning == true
            end
            if interfaces[IWD_NETWORK] then
                network_props[path] = interfaces[IWD_NETWORK]
            end
        end
        local networks = {}
        for i, entry in ipairs((ordered_reply.args or {})[1] or {}) do
            if i > 12 then
                break
            end
            local path = entry[1]
            local props = network_props[path]
            if props then
                table.insert(networks, {
                    path = path,
                    name = props.Name or "?",
                    secured = props.Type ~= nil and props.Type ~= "open",
                    known = props.KnownNetwork ~= nil,
                    connected = props.Connected == true,
                    percent = dbm_to_percent((tonumber(entry[2]) or -10000) / 100),
                })
            end
        end
        return { networks = networks, scanning = scanning }
    end

    local function connect(entry)
        local bus, station = net.bus, net.station
        if not bus or not station then
            return nil, "iwd unavailable"
        end
        local reply, err
        if entry.connected then
            reply, err = bus:call({
                destination = IWD,
                path = station,
                interface = IWD_STATION,
                member = "Disconnect",
                timeout_ms = 10000,
            })
        else
            -- Known and open networks connect directly; secured unknown
            -- ones need an auth agent we don't provide yet (POC).
            reply, err = bus:call({
                destination = IWD,
                path = entry.path,
                interface = IWD_NETWORK,
                member = "Connect",
                timeout_ms = 30000,
            })
        end
        -- The cached agent percent is stale either way; force a fresh read.
        assert(net.refresh)()
        return reply, err
    end

    -- Commands ride the snapshot only while iwd is usable, so their
    -- presence doubles as the availability check.
    local function publish()
        local available = net.bus ~= nil and net.station ~= nil
        self:publish({
            operstate = st.operstate,
            essid = st.essid,
            percent = st.percent,
            scan = available and scan or nil,
            list = available and list or nil,
            connect = available and connect or nil,
        })
    end

    local capture_running = false

    local function update_shell()
        if capture_running then
            return
        end
        capture_running = true
        loop.spawn(function()
            local result = process.capture({ "sh", "-c", SHELL_NETWORK_SCRIPT })
            capture_running = false
            if result and result.ok then
                local lines = {}
                for line in (result.stdout .. "\n"):gmatch("([^\n]*)\n") do
                    table.insert(lines, line)
                end
                st.operstate = trim(lines[1] or "down")
                st.essid = trim(lines[2] or "")
                st.percent = tonumber(lines[3])
                publish()
            end
        end)
    end

    local function update_iwd_now()
        local bus = net.bus
        if not bus or not net.station then
            return
        end
        local reply = bus:call({
            destination = IWD,
            path = net.station,
            interface = DBUS_PROPERTIES,
            member = "GetAll",
            args = { IWD_STATION },
            timeout_ms = 1000,
        })
        if not reply then
            -- Station gone (iwd restarted?); fall back to the shell path.
            net.station = nil
            update_shell()
            return
        end
        local props = (reply.args or {})[1] or {}
        local connected_path = props.ConnectedNetwork
        if props.State ~= "connected" or not connected_path then
            st.operstate, st.essid, st.percent = "down", "", 0
            publish()
            return
        end
        local network_reply = bus:call({
            destination = IWD,
            path = connected_path,
            interface = DBUS_PROPERTIES,
            member = "GetAll",
            args = { IWD_NETWORK },
            timeout_ms = 1000,
        })
        local essid = ""
        if network_reply then
            essid = ((network_reply.args or {})[1] or {}).Name or ""
        end
        if not net.percent then
            -- No agent report yet: read the real RSSI instead of guessing,
            -- so the pill never flashes an optimistic level at startup.
            local ordered_reply = bus:call({
                destination = IWD,
                path = net.station,
                interface = IWD_STATION,
                member = "GetOrderedNetworks",
                timeout_ms = 2000,
            })
            if ordered_reply then
                for _, entry in ipairs((ordered_reply.args or {})[1] or {}) do
                    if entry[1] == connected_path then
                        -- Signal strength arrives in units of 0.01 dBm.
                        local dbm = (tonumber(entry[2]) or -10000) / 100
                        net.percent = dbm_to_percent(dbm)
                        break
                    end
                end
            end
        end
        st.operstate, st.essid, st.percent = "up", essid, net.percent
        publish()
    end

    local function update_network()
        if net.station and net.bus then
            loop.spawn(update_iwd_now)
        else
            update_shell()
        end
    end

    -- Widget menu operations invalidate the cached agent percent after a
    -- connect/disconnect and force a fresh read.
    net.refresh = function()
        net.percent = nil
        update_network()
    end

    local function register_iwd_agent(bus)
        local ok, agent = pcall(function()
            return bus:export(IWD_AGENT_PATH, {
                [IWD_AGENT] = {
                    methods = {
                        Changed = {
                            in_signature = "oy",
                            call = function(_, _device, level)
                                local index = math.floor(tonumber(level) or 4) + 1
                                net.percent = IWD_LEVEL_PERCENT[index] or 10
                                update_network()
                            end,
                        },
                        Release = {
                            in_signature = "",
                            call = function() end,
                        },
                    },
                },
            })
        end)
        if not ok or not agent then
            log.warn("iwd signal agent export failed")
            return
        end
        local reply, err = bus:call({
            destination = IWD,
            path = net.station,
            interface = IWD_STATION,
            member = "RegisterSignalLevelAgent",
            args = {
                dbus.object_path(IWD_AGENT_PATH),
                dbus.array("n", IWD_SIGNAL_LEVELS),
            },
            timeout_ms = 2000,
        })
        if not reply then
            log.warn("iwd RegisterSignalLevelAgent failed", err or "unknown")
        end
    end

    -- iwd exposes everything on the system bus (iwctl is only a CLI over
    -- it), so prefer that over shelling out when a station exists.
    local function discover_iwd(bus)
        local object_manager = bus:proxy(IWD, "/", DBUS_OBJECT_MANAGER, { timeout_ms = 2000 })
        local managed_objects = object_manager:GetManagedObjects()
        if not managed_objects then
            return -- no iwd on this system; the shell fallback stays
        end
        for path, interfaces in pairs(managed_objects or {}) do
            if interfaces[IWD_STATION] then
                net.station = path
                break
            end
        end
        if net.station then
            register_iwd_agent(bus)
            update_iwd_now()
        end
    end

    local ok, bus = pcall(function()
        return dbus.system()
    end)
    if ok and bus then
        net.bus = bus
        local sub = bus:subscribe({
            path_namespace = "/org/freedesktop/NetworkManager",
        })
        loop.spawn(function()
            for signal in sub:events() do
                if signal.member == "PropertiesChanged" or signal.member == "StateChanged"
                    or signal.member == "DeviceAdded" or signal.member == "DeviceRemoved" then
                    update_network()
                end
            end
        end)
        -- iwd systems: Station state, scanning, and connected-network changes.
        local iwd_ok, iwd_sub = pcall(function()
            return bus:subscribe({
                path_namespace = "/net/connman/iwd",
            })
        end)
        if iwd_ok and iwd_sub then
            loop.spawn(function()
                for signal in iwd_sub:events() do
                    if signal.member == "PropertiesChanged" then
                        update_network()
                    end
                end
            end)
        end
        -- iwd's ObjectManager lives at /, outside the namespace above. Network
        -- objects appear and disappear there while GetOrderedNetworks grows.
        local objects_ok, objects_sub = pcall(function()
            return bus:subscribe({
                path = "/",
                interface = DBUS_OBJECT_MANAGER,
            })
        end)
        if objects_ok and objects_sub then
            loop.spawn(function()
                for signal in objects_sub:events() do
                    local object_path = (signal.args or {})[1]
                    if (signal.member == "InterfacesAdded" or signal.member == "InterfacesRemoved") and type(
                            object_path
                        ) == "string" and object_path:sub(1, #"/net/connman/iwd/") == "/net/connman/iwd/" then
                        -- Re-publish so open wifi menus refresh their list.
                        publish()
                    end
                end
            end)
        end
        loop.spawn(function()
            discover_iwd(bus)
        end)
    end

    update_network()

    -- Signal strength has no change signal; refresh once a minute.
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
        -- Show Scanning… immediately. A concurrent list fetch may still see
        -- Station.Scanning=false before Scan starts; wifi_scan_inflight keeps
        -- the indicator on until the Scan call returns, after which the
        -- station property (and its PropertiesChanged) own the flag.
        self.wifi_scan_inflight = true
        self:set_state(function(state)
            state.wifi_scanning = true
        end)
        self.scope:spawn(function()
            net.scan()
            self.wifi_scan_inflight = false
            -- Re-read so the header and list match post-Scan station state
            -- (Scanning true now, or already false with a fuller list).
            self:refresh_wifi_list()
        end)
    end,

    -- Coalesces concurrent refresh requests. A fetch can still be in flight
  -- when Scanning flips or InterfacesAdded fires; dropping those would leave
  -- the menu stuck on a partial list until the next open.
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
                state.wifi_status = "iwd unavailable"
            end)
            return
        end
        local result = net.list()
        if not result then
            return -- retain the last good snapshot on transient D-Bus failures
        end
        self:set_state(function(state)
            state.wifi_networks = result.networks
            -- Keep Scanning… while our Scan call is still in flight even if this
            -- snapshot was taken before iwd flipped Station.Scanning.
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
