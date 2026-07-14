--- XDG desktop portal clients for FileChooser and OpenURI.
--- Portal calls and response waits yield; call these functions from a
--- coroutine managed by keywork.loop (for example, inside loop.spawn).

local M = {}
local dbus = require("keywork.dbus")

local destination = "org.freedesktop.portal.Desktop"
local desktop_path = "/org/freedesktop/portal/desktop"
local request_interface = "org.freedesktop.portal.Request"
local token_counter = 0

local function next_token()
    token_counter = token_counter + 1
    return "keywork_" .. token_counter .. "_" .. os.time()
end

local function response_subscription(bus, path)
    return bus:subscribe({
        path = path,
        interface = request_interface,
        member = "Response",
    })
end

local function portal_request(bus, interface, member, args_before_options, options)
    local token = next_token()
    options.handle_token = dbus.variant("s", token)

    local unique_name, name_err = bus:unique_name()
    if not unique_name then return nil, name_err end
    local sender = unique_name:gsub("^:", ""):gsub("%.", "_")
    local predicted_path = "/org/freedesktop/portal/desktop/request/" .. sender .. "/" .. token
    local sub = response_subscription(bus, predicted_path)

    local args = {}
    for i = 1, #args_before_options do
        args[i] = args_before_options[i]
    end
    args[#args + 1] = dbus.array("{sv}", options)

    local reply, err = bus:call({
        destination = destination,
        path = desktop_path,
        interface = interface,
        member = member,
        args = args,
    })
    if not reply then
        sub:cancel()
        return nil, err
    end

    local actual_path = (reply.args or {})[1]
    if actual_path and actual_path ~= predicted_path then
        sub:cancel()
        sub = response_subscription(bus, actual_path)
    end

    local signal = sub:next()
    sub:cancel()
    if not signal then return nil, "portal response subscription ended" end
    local signal_args = signal.args or {}
    local response = signal_args[1]
    if response == 1 then return nil, "cancelled" end
    if response ~= 0 then return nil, "portal request failed" end
    return signal_args[2] or {}
end

local function byte_array(value)
    local bytes = {}
    for i = 1, #value do
        bytes[i] = value:byte(i)
    end
    return bytes
end

local function add_common_file_options(options, opts)
    if opts.multiple ~= nil then
        options.multiple = dbus.variant("b", opts.multiple)
    end
    if opts.directory ~= nil then
        options.directory = dbus.variant("b", opts.directory)
    end
    if opts.accept_label then
        options.accept_label = dbus.variant("s", opts.accept_label)
    end
    if opts.current_folder then
        options.current_folder = dbus.variant("ay", byte_array(opts.current_folder .. "\0"))
    end
    if opts.filters then
        local filters = {}
        for i, filter in ipairs(opts.filters) do
            local entries = {}
            for j, pattern in ipairs(filter.patterns or {}) do
                entries[j] = { dbus.uint32(0), pattern }
            end
            filters[i] = { filter.name or "", entries }
        end
        options.filters = dbus.variant("a(sa(us))", filters)
    end
end

local function with_session(callback)
    local bus, err = dbus.session()
    if not bus then return nil, err end
    local result, request_err = callback(bus)
    bus:close()
    return result, request_err
end

--- Opens the portal file chooser. Returns an array of file URIs, or nil and
--- an error ("cancelled" when dismissed by the user). Yieldable.
function M.open_file(opts)
    opts = opts or {}
    return with_session(function(bus)
        local options = {}
        add_common_file_options(options, opts)
        local results, err = portal_request(
            bus,
            "org.freedesktop.portal.FileChooser",
            "OpenFile",
            { opts.parent_window or "", opts.title or "Open File" },
            options
        )
        if not results then return nil, err end
        return results.uris or {}
    end)
end

--- Opens the portal save chooser. Returns the selected file URI, or nil and
--- an error ("cancelled" when dismissed by the user). Yieldable.
function M.save_file(opts)
    opts = opts or {}
    return with_session(function(bus)
        local options = {}
        add_common_file_options(options, opts)
        if opts.current_name then
            options.current_name = dbus.variant("s", opts.current_name)
        end
        if opts.current_file then
            options.current_file = dbus.variant("ay", byte_array(opts.current_file .. "\0"))
        end
        local results, err = portal_request(
            bus,
            "org.freedesktop.portal.FileChooser",
            "SaveFile",
            { opts.parent_window or "", opts.title or "Save File" },
            options
        )
        if not results then return nil, err end
        local uris = results.uris or {}
        if not uris[1] then return nil, "portal returned no URI" end
        return uris[1]
    end)
end

--- Asks the portal to open a URI. Returns true on success, or nil and an
--- error ("cancelled" when dismissed by the user). Yieldable.
function M.open_uri(uri, opts)
    assert(type(uri) == "string", "open_uri requires a URI string")
    opts = opts or {}
    return with_session(function(bus)
        local options = {}
        if opts.writable ~= nil then
            options.writable = dbus.variant("b", opts.writable)
        end
        if opts.ask ~= nil then
            options.ask = dbus.variant("b", opts.ask)
        end
        local results, err = portal_request(
            bus,
            "org.freedesktop.portal.OpenURI",
            "OpenURI",
            { opts.parent_window or "", uri },
            options
        )
        if not results then return nil, err end
        return true
    end)
end

return M
