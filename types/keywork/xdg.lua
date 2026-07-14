---@meta keywork.xdg

---@alias keywork.xdg.EntryType 'file' | 'dir' | 'symlink' | 'other'

---@class keywork.xdg.DirEntry
---@field name string
---@field type keywork.xdg.EntryType

---@class keywork.xdg.WriteOptions
---@field atomic? boolean Defaults to true.

local M = {}

---@return string
function M.data_home() end

---@return string
function M.config_home() end

---@return string
function M.cache_home() end

---@return string
function M.state_home() end

---@return string?
function M.runtime_dir() end

---@return string[]
function M.data_dirs() end

---@return string[]
function M.config_dirs() end

---@param path string
---@return true? ok
---@return string? error
function M.mkdir_all(path) end

---@param path string
---@return keywork.xdg.DirEntry[]? entries
---@return string? error
function M.read_dir(path) end

---@param path string
---@return string? data
---@return string? error
function M.read_file(path) end

---@param path     string
---@param data     string
---@param options? keywork.xdg.WriteOptions
---@return true? ok
---@return string? error
function M.write_file(path, data, options) end

return M
