---@meta keywork.net

---@class keywork.net.ConnectOptions
---@field connect_timeout? number  Connection setup timeout in seconds. Defaults to 30.
---@field proxy?           string  Explicit proxy URL. Ambient proxy environment variables are not used.

---@class keywork.net.Connection
local Connection = {}

--- Waits for and returns the next available byte chunk.
---@return string? chunk
function Connection:next() end

---@return fun(): string?
function Connection:chunks() end

--- Writes all bytes, yielding under backpressure when necessary.
---@param data string
---@return true? ok
---@return string? error
function Connection:write(data) end

function Connection:close() end

function Connection:cancel() end

---@return boolean
function Connection:closed() end

local M = {}

--- Establishes a protocol-neutral byte stream. Supported forms include
--- `tcp://host:port`, `tls://host:port`, and `unix:///absolute/path`.
--- TCP and TLS connections must be opened from a coroutine managed by
--- keywork.loop; Unix-domain connections complete synchronously.
---@param uri string
---@param options? keywork.net.ConnectOptions TCP/TLS connection options.
---@return keywork.net.Connection? connection
---@return string? error
function M.connect(uri, options) end

return M
