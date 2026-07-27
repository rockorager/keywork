--- Runs Varlink method handlers on Keywork tasks so they may yield. The
--- native completion handle owns the connection reference and becomes a
--- harmless no-op after a final reply, error, disconnect, or server close.

local native, client_methods = ...

function client_methods:call(method, parameters)
    local request, err = self:request(method, parameters or {}, false)
    if not request then
        return nil, err
    end
    local response = request:next()
    if not response then
        return nil, "Varlink connection closed"
    end
    if response.error then
        return nil, response.error, response.parameters
    end
    return response.parameters
end

function client_methods:observe(method, parameters)
    return self:request(method, parameters or {}, true)
end

local function dispatch(completion, handler, method, more, parameters)
    local loop = require("keywork.loop")
    local call = {
        method = method,
        more = more,
    }

    function call:notify(value)
        return completion:notify(value or {})
    end

    function call:error(name, parameters)
        return completion:error(name, parameters or {})
    end

    loop.spawn(function()
        local ok, result = pcall(handler, call, parameters)
        if ok then
            completion:reply(result or {})
        else
            local message = tostring(result)
            require("keywork.log").warn("Varlink method failed: " .. message)
            completion:error("org.keywork.LuaError", { message = message })
        end
    end)
end

return dispatch
