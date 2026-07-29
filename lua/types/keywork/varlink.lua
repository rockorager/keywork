---@meta keywork.varlink

---@class keywork.varlink.Call
---@field method string
---@field more boolean Whether the caller requested a streaming response.
local Call = {}

--- Sends a non-final streaming reply. The call must have `more == true`.
---@param parameters? table<string, keywork.json.Value>
---@return boolean? sent
---@return string? error
function Call:notify(parameters) end

--- Sends a final Varlink error.
---@param name string
---@param parameters? table<string, keywork.json.Value>
function Call:error(name, parameters) end

---@alias keywork.varlink.Method fun(call: keywork.varlink.Call, parameters: table<string, keywork.json.Value>): table<string, keywork.json.Value>?

---@class keywork.varlink.ServeOptions
---@field address? string Absolute Unix socket path. When omitted, use systemd socket activation.
---@field methods table<string, keywork.varlink.Method>

---@class keywork.varlink.Server
local Server = {}

function Server:close() end

---@return boolean
function Server:closed() end

---@class keywork.varlink.Response
---@field parameters table<string, keywork.json.Value>
---@field error? string
---@field continues boolean

---@class keywork.varlink.Request
local Request = {}

--- Waits for the next response, or returns nil after the final response.
---@return keywork.varlink.Response?
function Request:next() end

---@return fun(): keywork.varlink.Response?
function Request:replies() end

--- Cancels this request by closing its client connection.
function Request:cancel() end

---@class keywork.varlink.Client
local Client = {}

--- Calls a method and waits for its final response.
---@param method string
---@param parameters? table<string, keywork.json.Value>
---@return table<string, keywork.json.Value>? response
---@return string? error
---@return table<string, keywork.json.Value>? error_parameters
function Client:call(method, parameters) end

--- Starts a streaming method call.
---@param method string
---@param parameters? table<string, keywork.json.Value>
---@return keywork.varlink.Request? request
---@return string? error
function Client:observe(method, parameters) end

function Client:close() end

---@return boolean
function Client:closed() end

local M = {}

--- Creates a Varlink server. Method handlers run as Keywork tasks and may
--- yield. Omitting `address` consumes systemd Varlink/listen-fd activation.
---@param options keywork.varlink.ServeOptions
---@return keywork.varlink.Server? server
---@return string? error
function M.serve(options) end

--- Connects to a Varlink Unix socket.
---@param address string Absolute Unix socket path.
---@return keywork.varlink.Client? client
---@return string? error
function M.connect(address) end

return M
