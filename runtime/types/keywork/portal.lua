---@meta keywork.portal

---@class keywork.portal.Filter
---@field name?     string
---@field patterns? string[]

---@class keywork.portal.FileOptions
---@field parent_window?  string
---@field title?          string
---@field multiple?       boolean
---@field directory?      boolean
---@field accept_label?   string
---@field current_folder? string
---@field filters?        keywork.portal.Filter[]

---@class keywork.portal.SaveOptions: keywork.portal.FileOptions
---@field current_name? string
---@field current_file? string

---@class keywork.portal.OpenUriOptions
---@field parent_window? string
---@field writable?      boolean
---@field ask?           boolean

local M = {}

--- Opens the file chooser. Must be called from a loop task.
---@param options? keywork.portal.FileOptions
---@return string[]? uris
---@return string? error
function M.open_file(options) end

--- Opens the save chooser. Must be called from a loop task.
---@param options? keywork.portal.SaveOptions
---@return string? uri
---@return string? error
function M.save_file(options) end

--- Asks the desktop portal to open a URI. Must be called from a loop task.
---@param uri      string
---@param options? keywork.portal.OpenUriOptions
---@return true? ok
---@return string? error
function M.open_uri(uri, options) end

return M
