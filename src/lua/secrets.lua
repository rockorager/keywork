--- High-level client for the freedesktop.org Secret Service API.
--- All operations yield and must run inside a keywork.loop task. This client
--- uses the baseline "plain" session algorithm and relies on the local session
--- bus for transport isolation; returned and supplied secrets are Lua strings.

local M = {}
local dbus = require("keywork.dbus")

local destination = "org.freedesktop.secrets"
local service_path = "/org/freedesktop/secrets"
local service_interface = "org.freedesktop.Secret.Service"
local collection_interface = "org.freedesktop.Secret.Collection"
local item_interface = "org.freedesktop.Secret.Item"
local prompt_interface = "org.freedesktop.Secret.Prompt"
local session_interface = "org.freedesktop.Secret.Session"
local default_collection = "/org/freedesktop/secrets/aliases/default"

local function call(bus, path, interface, member, args, target)
    return bus:call({
        destination = target or destination,
        path = path,
        interface = interface,
        member = member,
        args = args or {},
        timeout_ms = 5000,
    })
end

local function checked_attributes(attributes)
    assert(type(attributes) == "table", "secret attributes must be a table")
    local count = 0
    for name, value in pairs(attributes) do
        assert(type(name) == "string", "secret attribute names must be strings")
        assert(type(value) == "string", "secret attribute values must be strings")
        count = count + 1
    end
    assert(count > 0, "at least one secret attribute is required")
    return attributes
end

local function byte_array(value)
    local bytes = {}
    for index = 1, #value do bytes[index] = value:byte(index) end
    return bytes
end

local function close_client(client)
    call(client.bus, client.session, session_interface, "Close", nil, client.destination)
    client.bus:close()
end

local function client_call(client, path, interface, member, args)
    return call(client.bus, path, interface, member, args, client.destination)
end

local function open_client()
    local bus, err = dbus.session()
    if not bus then return nil, err or "session bus unavailable" end

    local reply
    reply, err = call(bus, service_path, service_interface, "OpenSession", {
        dbus.string("plain"),
        dbus.variant("s", ""),
    })
    if not reply then
        bus:close()
        return nil, err or "failed to open Secret Service session"
    end
    local owner = reply.sender
    local session = (reply.args or {})[2]
    if type(owner) ~= "string" or owner:sub(1, 1) ~= ":" or type(session) ~= "string" or session == "/" then
        bus:close()
        return nil, "Secret Service returned an invalid owner or session"
    end
    return { bus = bus, destination = owner, session = session }
end

local function run_prompt(client, prompt, parent_window)
    if prompt == nil or prompt == "/" then return true end
    local subscription = client.bus:subscribe({
        sender = client.destination,
        path = prompt,
        interface = prompt_interface,
        member = "Completed",
    })
    local reply, err = client_call(client, prompt, prompt_interface, "Prompt", {
        dbus.string(parent_window or ""),
    })
    if not reply then
        subscription:cancel()
        return nil, err or "Secret Service prompt failed"
    end
    local signal = subscription:next()
    subscription:cancel()
    if not signal then return nil, "Secret Service prompt ended without a result" end
    local args = signal.args or {}
    if args[1] then return nil, "cancelled" end
    return true, args[2]
end

local function search(client, attributes)
    local reply, err = client_call(client, service_path, service_interface, "SearchItems", {
        dbus.array("{ss}", checked_attributes(attributes)),
    })
    if not reply then return nil, nil, err or "Secret Service search failed" end
    local args = reply.args or {}
    return args[1] or {}, args[2] or {}
end

local function unlock(client, paths, parent_window)
    if #paths == 0 then return {} end
    local reply, err = client_call(client, service_path, service_interface, "Unlock", {
        dbus.array("o", paths),
    })
    if not reply then return nil, err or "failed to unlock secret items" end
    local args = reply.args or {}
    local unlocked = args[1] or {}
    local prompt = args[2]
    if #unlocked > 0 or prompt == nil or prompt == "/" then return unlocked end
    local ok, result = run_prompt(client, prompt, parent_window)
    if not ok then return nil, result end
    if type(result) ~= "table" then return nil, "Secret Service prompt returned invalid unlock results" end
    return result
end

--- Finds the first item matching every attribute and returns its secret.
--- The optional metadata result contains the item object path and MIME type.
function M.lookup(attributes, options)
    options = options or {}
    checked_attributes(attributes)
    local client, err = open_client()
    if not client then return nil, nil, err end

    local unlocked, locked
    unlocked, locked, err = search(client, attributes)
    if not unlocked then
        close_client(client)
        return nil, nil, err
    end
    local paths = {}
    for _, path in ipairs(unlocked) do paths[#paths + 1] = path end
    if #paths == 0 then
        local newly_unlocked
        newly_unlocked, err = unlock(client, locked, options.parent_window)
        if not newly_unlocked then
            close_client(client)
            return nil, nil, err
        end
        for _, path in ipairs(newly_unlocked) do paths[#paths + 1] = path end
    end
    if #paths == 0 then
        close_client(client)
        return nil
    end

    local reply
    reply, err = client_call(client, service_path, service_interface, "GetSecrets", {
        dbus.array("o", paths),
        dbus.object_path(client.session),
    })
    if not reply then
        close_client(client)
        return nil, nil, err or "failed to retrieve secret"
    end
    local secrets = (reply.args or {})[1] or {}
    for _, path in ipairs(paths) do
        local encoded = secrets[path]
        if encoded then
            local value = encoded[3]
            if type(value) ~= "string" then
                close_client(client)
                return nil, nil, "Secret Service returned an invalid secret value"
            end
            local metadata = { item = path, content_type = encoded[4] or "application/octet-stream" }
            close_client(client)
            return value, metadata
        end
    end
    close_client(client)
    return nil
end

--- Stores a secret in the default collection, replacing an item with the
--- same attributes unless replace is explicitly false.
function M.store(options)
    assert(type(options) == "table", "store requires an options table")
    assert(type(options.label) == "string", "store requires a label")
    assert(type(options.secret) == "string", "store requires a secret string")
    local attributes = checked_attributes(options.attributes)
    local client, err = open_client()
    if not client then return nil, err end

    local properties = dbus.array("{sv}", {
        ["org.freedesktop.Secret.Item.Label"] = dbus.variant("s", options.label),
        ["org.freedesktop.Secret.Item.Attributes"] = dbus.variant("a{ss}", attributes),
    })
    local secret = dbus.struct("(oayays)", {
        dbus.object_path(client.session),
        dbus.array("y", {}),
        dbus.array("y", byte_array(options.secret)),
        options.content_type or "text/plain; charset=utf-8",
    })
    local reply
    reply, err = client_call(
        client,
        options.collection or default_collection,
        collection_interface,
        "CreateItem",
        { properties, secret, dbus.boolean(options.replace ~= false) }
    )
    if not reply then
        close_client(client)
        return nil, err or "failed to store secret"
    end
    local args = reply.args or {}
    local item = args[1]
    local ok, prompt_result = run_prompt(client, args[2], options.parent_window)
    if not ok then
        close_client(client)
        return nil, prompt_result
    end
    if item == "/" and type(prompt_result) == "string" then item = prompt_result end
    if type(item) ~= "string" or item == "/" then
        close_client(client)
        return nil, "Secret Service did not return a stored item"
    end
    close_client(client)
    return item
end

--- Deletes every item matching all supplied attributes and returns the count.
function M.delete(attributes, options)
    options = options or {}
    checked_attributes(attributes)
    local client, err = open_client()
    if not client then return nil, err end
    local unlocked, locked
    unlocked, locked, err = search(client, attributes)
    if not unlocked then
        close_client(client)
        return nil, err
    end
    local paths = {}
    for _, path in ipairs(unlocked) do paths[#paths + 1] = path end
    for _, path in ipairs(locked) do paths[#paths + 1] = path end

    local deleted = 0
    for _, path in ipairs(paths) do
        local reply
        reply, err = client_call(client, path, item_interface, "Delete")
        if not reply then
            close_client(client)
            return nil, err or "failed to delete secret item"
        end
        local ok
        ok, err = run_prompt(client, (reply.args or {})[1], options.parent_window)
        if not ok then
            close_client(client)
            return nil, err
        end
        deleted = deleted + 1
    end
    close_client(client)
    return deleted
end

return M
