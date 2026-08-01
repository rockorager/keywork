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
local NM_ACTIVE = "org.freedesktop.NetworkManager.Connection.Active"
local NM_SETTINGS_CONNECTION = "org.freedesktop.NetworkManager.Settings.Connection"
local NM_DEVICE_TYPE_WIFI = 2
local NM_DEVICE_STATE_ACTIVATED = 100
local NM_ACTIVE_STATE_ACTIVATED = 2
local NM_ACTIVE_STATE_DEACTIVATED = 4

local NM_AP_FLAG_PRIVACY = 0x1
local NM_AP_SEC_KEY_MGMT_PSK = 0x100
local NM_AP_SEC_KEY_MGMT_802_1X = 0x200
local NM_AP_SEC_KEY_MGMT_SAE = 0x400
local NM_AP_SEC_KEY_MGMT_OWE = 0x800
local NM_AP_SEC_KEY_MGMT_OWE_TM = 0x1000
local NM_AP_SEC_KEY_MGMT_EAP_SUITE_B_192 = 0x2000

local function has_flag(value, flag)
    return math.floor((value or 0) / flag) % 2 == 1
end

local function security_kind(flags, wpa_flags, rsn_flags)
    local function advertised(flag)
        return has_flag(wpa_flags, flag) or has_flag(rsn_flags, flag)
    end

    if advertised(NM_AP_SEC_KEY_MGMT_PSK) then return "wpa-psk" end
    if advertised(NM_AP_SEC_KEY_MGMT_SAE) then return "sae" end
    if advertised(NM_AP_SEC_KEY_MGMT_OWE) or advertised(NM_AP_SEC_KEY_MGMT_OWE_TM) then
        return "owe"
    end
    if advertised(NM_AP_SEC_KEY_MGMT_802_1X) or advertised(NM_AP_SEC_KEY_MGMT_EAP_SUITE_B_192) then
        return "enterprise"
    end
    if has_flag(flags, NM_AP_FLAG_PRIVACY) then return "wep" end
    return "open"
end

local function requires_password(security)
    return security == "wpa-psk" or security == "sae" or security == "wep"
end

local function password_error(err)
    if err == "Connection failed" then
        return "Couldn’t connect. Check the password and try again."
    elseif err == "Connection timed out" then
        return "Connection timed out. Check the password and try again."
    end
    return err or "Couldn’t connect to this network."
end

local function connection_settings(entry, password)
    local security
    if entry.security == "wpa-psk" or entry.security == "sae" then
        security = {
            ["key-mgmt"] = dbus.variant("s", entry.security),
            psk = dbus.variant("s", password),
        }
    elseif entry.security == "wep" then
        security = {
            ["key-mgmt"] = dbus.variant("s", "none"),
            ["wep-key0"] = dbus.variant("s", password),
        }
    end

    local settings = {}
    if security then
        settings["802-11-wireless"] = {
            security = dbus.variant("s", "802-11-wireless-security"),
        }
        settings["802-11-wireless-security"] = security
    end
    return dbus.array("{sa{sv}}", settings)
end

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

local function network_name(entry, text_color, subtle_color)
    if entry.connected then
        return kw.column({
            spacing = 0,
            children = {
                label(entry.name, text_color),
                kw.text("Connected", {
                    color = subtle_color,
                    font_size = 12,
                    line_height = 16,
                    max_lines = 1,
                }),
            },
        })
    end
    return label(entry.name, text_color)
end

local function network_row(palette, entry, on_select)
    local icon_color = entry.connected and palette.selection or palette.muted
    local text_color = entry.connected and palette.foreground or palette.muted
    local trailing
    if entry.connected then
        trailing = kw.icon({ name = "object-select", color = palette.foreground })
    elseif entry.known then
        trailing = kw.text("Saved", {
            color = palette.subtle,
            font_size = 12,
            line_height = 16,
        })
    elseif entry.secured and not entry.known then
        trailing = kw.icon({ name = "network-wireless-encrypted", color = palette.subtle })
    end

    local network_icon = kw.container({
        background = entry.connected and palette.accent or nil,
        radius = palette.theme.radius[2],
        min_width = 32,
        min_height = 32,
        horizontal_align = "center",
        vertical_align = "center",
        child = kw.icon({
            name = wifi_signal_icon(entry.percent or 0),
            size = 20,
            color = entry.connected and palette.on_accent or icon_color,
        }),
    })

    local children = {
        network_icon,
        kw.expanded({
            child = network_name(entry, text_color, palette.subtle),
        }),
    }
    if trailing then
        children[#children + 1] = trailing
    end
    return kw.menu_item({
        id = "wifi-" .. entry.path,
        selected = entry.connected,
        on_activate = function()
            on_select(entry)
        end,
        child = kw.row({
            spacing = palette.space[2],
            align = "center",
            children = children,
        }),
    })
end

local function wifi_status_row(palette, status)
    local failed = status:lower():find("failed", 1, true) ~= nil
    local color = failed and palette.error or palette.muted
    return kw.padding({
        x = palette.space[3],
        y = palette.space[2],
        child = kw.row({
            spacing = palette.space[2],
            align = "center",
            children = {
                kw.icon({ name = failed and "dialog-warning" or "dialog-information", color = color }),
                kw.expanded({
                    child = kw.text(status, {
                        color = color,
                        font_size = 12,
                        line_height = 16,
                        max_lines = 2,
                    }),
                }),
            },
        }),
    })
end

local function connected_network(networks)
    for _, entry in ipairs(networks or {}) do
        if entry.connected then
            return entry
        end
    end
end

local function wifi_auth_page(palette, auth, on_back, on_change, on_submit)
    on_back = on_back or function() end
    on_change = on_change or function(_) end
    on_submit = on_submit or function(_) end
    local theme = palette.theme
    local helper_text = "Enter the password for this network."
    local helper_color = palette.subtle
    if auth.connecting then
        helper_text = "Connecting…"
    elseif auth.error then
        helper_text = auth.error
        helper_color = palette.error
    end
    return kw.menu_surface({
        child = kw.column({
            children = {
                kw.menu_label({
                    min_height = 40,
                    child = kw.row({
                        spacing = palette.space[1],
                        align = "center",
                        children = {
                            kw.icon_button({
                                id = "wifi-auth-back",
                                icon = "go-previous",
                                size = "small",
                                appearance = "subtle",
                                disabled = auth.connecting,
                                on_activate = on_back,
                            }),
                            kw.text("Connect to Wi-Fi", {
                                color = palette.foreground,
                                font_size = 16,
                                line_height = 22,
                            }),
                        },
                    }),
                }),
                kw.menu_separator({}),
                kw.padding({
                    all = palette.space[3],
                    child = kw.column({
                        align = "stretch",
                        spacing = palette.space[3],
                        children = {
                            kw.row({
                                spacing = palette.space[3],
                                align = "center",
                                children = {
                                    kw.container({
                                        background = palette.accent,
                                        radius = theme.radius[2],
                                        min_width = 40,
                                        min_height = 40,
                                        horizontal_align = "center",
                                        vertical_align = "center",
                                        child = kw.icon({
                                            name = "network-wireless-encrypted",
                                            color = palette.on_accent,
                                        }),
                                    }),
                                    kw.expanded({
                                        child = kw.column({
                                            spacing = 0,
                                            children = {
                                                kw.text(auth.name or "Wi-Fi network", {
                                                    color = palette.foreground,
                                                    font_size = 16,
                                                    line_height = 22,
                                                    max_lines = 1,
                                                }),
                                                kw.text("Password required", {
                                                    color = palette.subtle,
                                                    font_size = 12,
                                                    line_height = 16,
                                                }),
                                            },
                                        }),
                                    }),
                                },
                            }),
                            kw.text_field({
                                id = "wifi-password",
                                placeholder = "Password",
                                value = auth.password or "",
                                obscured = true,
                                autofocus = auth.autofocus ~= false,
                                on_change = on_change,
                                on_submit = on_submit,
                            }),
                            kw.text(helper_text, {
                                color = helper_color,
                                font_size = 12,
                                line_height = 16,
                                max_lines = 2,
                            }),
                            kw.button({
                                id = "wifi-auth-connect",
                                label = auth.connecting and "Connecting…" or "Connect",
                                appearance = "primary",
                                disabled = auth.connecting,
                                on_activate = function()
                                    on_submit(auth.password or "")
                                end,
                            }),
                        },
                    }),
                }),
            },
        }),
    })
end

local function wifi_menu(palette, wifi, on_select, on_scan)
    wifi = wifi or {}
    if wifi.auth then
        return wifi_auth_page(
            palette,
            wifi.auth,
            wifi.on_auth_back,
            wifi.on_auth_change,
            wifi.on_auth_submit
        )
    end
    on_select = on_select or function(_) end
    local header_children = {
        kw.text("Network", {
            color = palette.foreground,
            font_size = 16,
            line_height = 22,
        }),
        kw.spacer(),
    }
    if wifi.scanning then
        header_children[#header_children + 1] = kw.text("Scanning…", {
            color = palette.subtle,
            font_size = 12,
            line_height = 16,
        })
    end
    header_children[#header_children + 1] = kw.icon_button({
        id = "wifi-refresh",
        icon = "view-refresh",
        size = "small",
        appearance = "subtle",
        disabled = wifi.scanning or on_scan == nil,
        on_activate = on_scan,
    })
    local rows = {
        kw.menu_label({
            min_height = 40,
            child = kw.row({
                align = "center",
                children = header_children,
            }),
        }),
    }

    local connected = connected_network(wifi.networks)

    if connected then
        rows[#rows + 1] = kw.menu_label({ text = "Connected" })
        rows[#rows + 1] = network_row(palette, connected, on_select)
        rows[#rows + 1] = kw.menu_separator({})
    end

    rows[#rows + 1] = kw.menu_label({ text = connected and "Available networks" or "Wi-Fi" })

    if wifi.status then
        rows[#rows + 1] = wifi_status_row(palette, wifi.status)
    end

    for _, entry in ipairs(wifi.networks or {}) do
        if not entry.connected then
            rows[#rows + 1] = network_row(palette, entry, on_select)
        end
    end

    local available_count = #(wifi.networks or {}) - (connected and 1 or 0)
    if available_count == 0 then
        local empty_label
        if not wifi.networks then
            empty_label = "Loading networks…"
        elseif wifi.scanning then
            empty_label = "Looking for networks…"
        elseif connected then
            empty_label = "No other networks found"
        else
            empty_label = "No networks found"
        end
        rows[#rows + 1] = kw.padding({
            x = palette.space[3],
            y = palette.space[3],
            child = label(empty_label, palette.subtle),
        })
    end

    return kw.menu_surface({
        child = kw.column({ children = rows }),
    })
end

local WifiMenu = kw.component({
    hot_id = "WifiMenu",
    hot_version = 1,
    build = function(self)
        return wifi_menu(self.props.colors, self.props.wifi, self.props.on_select, self.props.on_scan)
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
                local security = security_kind(flags, tonumber(props.WpaFlags), tonumber(props.RsnFlags))
                local candidate = {
                    path = path,
                    name = name,
                    security = security,
                    secured = security ~= "open",
                    requires_password = requires_password(security),
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

    local function wait_for_activation(active_path)
        local deadline = loop.monotonic_ms() + 90000
        while loop.monotonic_ms() < deadline do
            local props = get_all(active_path, NM_ACTIVE, 2000)
            if not props then
                return nil, "Connection failed"
            end

            local state = tonumber(props.State)
            if state == NM_ACTIVE_STATE_ACTIVATED then
                return true
            elseif state == NM_ACTIVE_STATE_DEACTIVATED then
                return nil, "Connection failed"
            end
            loop.sleep(500)
        end
        return nil, "Connection timed out"
    end

    local function delete_connection(connection_path)
        local _, err = assert(net.bus):call({
            destination = NETWORK_MANAGER,
            path = connection_path,
            interface = NM_SETTINGS_CONNECTION,
            member = "Delete",
            timeout_ms = 10000,
        })
        if err then log.warn("NetworkManager temporary profile cleanup failed", err) end
    end

    local function save_connection(connection_path)
        return assert(net.bus):call({
            destination = NETWORK_MANAGER,
            path = connection_path,
            interface = NM_SETTINGS_CONNECTION,
            member = "Update2",
            args = {
                dbus.array("{sa{sv}}", {}),
                dbus.uint32(0x1), -- NM_SETTINGS_UPDATE2_FLAG_TO_DISK
                dbus.array("{sv}", {}),
            },
            timeout_ms = 10000,
        })
    end

    local function connect(entry, password)
        local bus, device = net.bus, net.device
        if not bus or not device then
            return nil, "NetworkManager unavailable"
        end
        if entry.security == "enterprise" and not entry.known then
            return nil, "Enterprise Wi-Fi isn't supported yet"
        end
        if entry.requires_password and not entry.known and (not password or password == "") then
            return nil, "Enter the network password"
        end

        local reply, err
        local active_path
        local connection_path
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
            active_path = reply and (reply.args or {})[1] or nil
        else
            reply, err = bus:call({
                destination = NETWORK_MANAGER,
                path = NETWORK_MANAGER_PATH,
                interface = NETWORK_MANAGER,
                member = "AddAndActivateConnection2",
                args = {
                    connection_settings(entry, password),
                    dbus.object_path(device),
                    dbus.object_path(entry.path),
                    dbus.array("{sv}", {
                        persist = dbus.variant("s", "memory"),
                    }),
                },
                timeout_ms = 30000,
            })
            connection_path = reply and (reply.args or {})[1] or nil
            active_path = reply and (reply.args or {})[2] or nil
        end

        if not reply then
            assert(net.refresh)()
            return nil, err
        end
        if active_path then
            local activated, activation_err = wait_for_activation(active_path)
            if not activated then
                if connection_path then delete_connection(connection_path) end
                assert(net.refresh)()
                return nil, activation_err
            end
        end
        if connection_path then
            local saved, save_err = save_connection(connection_path)
            if not saved then
                log.warn("NetworkManager profile save failed", save_err or "unknown")
            end
        end
        assert(net.refresh)()
        return reply
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

local Network = kw.component({
    init = function(self)
        self.revision = kw.signal(0)
        self.wifi_menu_open = false
        self.wifi_auth_entry = nil
        self.wifi_auth_token = nil
        self.wifi_password = ""
        self.wifi_auth_error = nil
        self.wifi_auth_connecting = false
    end,

    hot_id = "Network",
    hot_version = 2,
    mutate = function(self, fn)
        if fn then fn(self) end
        self.revision:update(function(value) return value + 1 end)
    end,
    start = function(self)
        self.wifi_refresh_pending = false --[[@as boolean]]
        self.wifi_fetching = false
        self.wifi_scan_inflight = false
        self.wifi_tap = function()
            self:toggle_wifi_menu()
        end
        self.net = network_service:use(self.scope, function()
            if self.wifi_menu_open then self:refresh_wifi_list() end
        end)
    end,

    toggle_wifi_menu = function(self)
        self:mutate(function(state)
            state.wifi_menu_open = not state.wifi_menu_open
            if state.wifi_menu_open then
                state.wifi_status = nil
                state:refresh_wifi_list()
                state:scan_wifi()
            else
                state.wifi_auth_entry = nil
                state.wifi_auth_token = nil
                state.wifi_password = ""
                state.wifi_auth_error = nil
                state.wifi_auth_connecting = false
            end
        end)
    end,

    scan_wifi = function(self)
        local net = self.net and self.net()
        if not net or not net.scan or self.wifi_scan_inflight then
            return
        end
        -- Show Scanning… while NetworkManager accepts the request; LastScan
        -- then keeps the service-level indicator active until completion.
        self.wifi_scan_inflight = true
        self:mutate(function(state)
            state.wifi_scanning = true
        end)
        self.scope:spawn(function()
            local reply, err = net.scan()
            self.wifi_scan_inflight = false
            if not reply then
                self:mutate(function(state)
                    state.wifi_status = "Scan failed: " .. (err or "unknown")
                end)
            end
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
        local net = self.net and self.net()
        if not net or not net.list then
            self:mutate(function(state)
                state.wifi_status = "NetworkManager unavailable"
            end)
            return
        end
        local result = net.list()
        if not result then
            return -- retain the last good snapshot on transient D-Bus failures
        end
        self:mutate(function(state)
            state.wifi_networks = result.networks
            -- Keep Scanning… while RequestScan itself is still in flight even
            -- if this snapshot predates the service-level scan flag.
            state.wifi_scanning = result.scanning or self.wifi_scan_inflight
        end)
    end,

    connect_wifi = function(self, entry)
        local net = self.net and self.net()
        if not net or not net.connect then
            return
        end
        self.scope:spawn(function()
            self:mutate(function(state)
                state.wifi_status = entry.connected and "Disconnecting…" or ("Connecting to " .. entry.name .. "…")
            end)
            local reply, err = net.connect(entry)
            self:mutate(function(state)
                state.wifi_status = reply and nil or ("Failed: " .. (err or "unknown"))
            end)
            self:refresh_wifi_list()
        end)
    end,

    select_wifi = function(self, entry)
        if not entry.known and entry.security == "enterprise" then
            self:mutate(function(state)
                state.wifi_status = "Enterprise Wi-Fi isn't supported yet"
            end)
        elseif not entry.known and entry.requires_password then
            self:mutate(function(state)
                state.wifi_auth_entry = entry
                state.wifi_auth_token = {}
                state.wifi_password = ""
                state.wifi_auth_error = nil
                state.wifi_auth_connecting = false
            end)
        else
            self:connect_wifi(entry)
        end
    end,

    submit_wifi_password = function(self, password)
        local net = self.net and self.net()
        local entry = self.wifi_auth_entry
        local token = self.wifi_auth_token
        if not net or not net.connect or not entry or self.wifi_auth_connecting then
            return
        end
        if password == "" then
            self:mutate(function(state)
                state.wifi_auth_error = "Enter the network password."
            end)
            return
        end

        self:mutate(function(state)
            state.wifi_password = password
            state.wifi_auth_error = nil
            state.wifi_auth_connecting = true
        end)
        self.scope:spawn(function()
            local reply, err = net.connect(entry, password)
            self:mutate(function(state)
                if state.wifi_auth_token ~= token then return end
                state.wifi_auth_connecting = false
                if reply then
                    state.wifi_auth_entry = nil
                    state.wifi_auth_token = nil
                    state.wifi_password = ""
                    state.wifi_auth_error = nil
                else
                    state.wifi_auth_error = password_error(err)
                end
            end)
            self:refresh_wifi_list()
        end)
    end,

    build_wifi_menu = function(self)
        local palette = self.props.colors
        local auth
        if self.wifi_auth_entry then
            auth = {
                name = self.wifi_auth_entry.name,
                password = self.wifi_password,
                error = self.wifi_auth_error,
                connecting = self.wifi_auth_connecting,
            }
        end
        return wifi_menu(
            palette,
            {
                status = self.wifi_status,
                scanning = self.wifi_scanning,
                networks = self.wifi_networks,
                auth = auth,
                on_auth_back = function()
                    self:mutate(function(state)
                        if state.wifi_auth_connecting then return end
                        state.wifi_auth_entry = nil
                        state.wifi_auth_token = nil
                        state.wifi_password = ""
                        state.wifi_auth_error = nil
                    end)
                end,
                on_auth_change = function(password)
                    self:mutate(function(state)
                        state.wifi_password = password
                        state.wifi_auth_error = nil
                    end)
                end,
                on_auth_submit = function(password)
                    self:submit_wifi_password(password)
                end,
            },
            function(entry)
                self:select_wifi(entry)
            end,
            function()
                self:scan_wifi()
            end
        )
    end,

    build = function(self)
        self.revision()
        local palette = self.props.colors
        local net = self.net and self.net() or { operstate = "down", essid = "", percent = 0 }
        return kw.popover({
            id = "network",
            anchor = pill_from_values(palette, net.operstate, net.essid, net.percent, self.wifi_tap),
            open = self.wifi_menu_open,
            placement = { edge = "bottom", alignment = "end", gap = palette.space[1] },
            width = 340,
            content = function()
                return self:build_wifi_menu()
            end,
            on_close = function()
                self:mutate(function(state)
                    state.wifi_menu_open = false
                    state.wifi_auth_entry = nil
                    state.wifi_auth_token = nil
                    state.wifi_password = ""
                    state.wifi_auth_error = nil
                    state.wifi_auth_connecting = false
                end)
            end,
        })
    end,
})

return {
    Network = Network,
    Menu = WifiMenu,
}
