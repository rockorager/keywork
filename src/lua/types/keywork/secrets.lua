---@meta keywork.secrets

--- Client for the freedesktop.org Secret Service. It uses the baseline
--- "plain" session algorithm and relies on local session-bus isolation.
--- Secrets supplied to and returned from this module are ordinary Lua strings.

---@alias keywork.secrets.Attributes table<string, string>

---@class keywork.secrets.LookupOptions
---@field parent_window? string Secret Service parent-window identifier.

---@class keywork.secrets.Metadata
---@field item         string
---@field content_type string

---@class keywork.secrets.StoreOptions
---@field label          string
---@field attributes     keywork.secrets.Attributes
---@field secret         string
---@field replace?       boolean
---@field collection?    string Secret Service collection object path; defaults to the `default` alias.
---@field content_type?  string
---@field parent_window? string Secret Service parent-window identifier.

local M = {}

--- Finds the first item matching every attribute. Must run in a loop task.
---@param attributes keywork.secrets.Attributes
---@param options?   keywork.secrets.LookupOptions
---@return string? secret
---@return keywork.secrets.Metadata? metadata
---@return string? error
function M.lookup(attributes, options) end

--- Stores a secret. Must run in a loop task.
---@param options keywork.secrets.StoreOptions
---@return string? item_path
---@return string? error
function M.store(options) end

--- Deletes every item matching all attributes. Must run in a loop task.
---@param attributes keywork.secrets.Attributes
---@param options?   keywork.secrets.LookupOptions
---@return integer? deleted
---@return string? error
function M.delete(attributes, options) end

return M
