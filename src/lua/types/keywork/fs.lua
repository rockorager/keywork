---@meta keywork.fs

---@alias keywork.fs.EntryType 'file' | 'dir' | 'symlink' | 'other'
---@class keywork.fs.Entry
---@field name string
---@field type keywork.fs.EntryType
---@class keywork.fs.Stat
---@field type keywork.fs.EntryType
---@field size integer
---@field mtime_sec integer
---@field mtime_nsec integer
---@field identity? string Stable filesystem device/inode identity when supported.

local M = {}
---@param path string
---@return string? data
---@return string? error
function M.read(path) end
---@param path string
---@param data string
---@param options? {atomic?: boolean}
---@return true? ok
---@return string? error
function M.write(path, data, options) end
---@param path string
---@return keywork.fs.Entry[]? entries
---@return string? error
function M.list(path) end
---@param path string
---@param options? {parents?: boolean}
---@return true? ok
---@return string? error
function M.mkdir(path, options) end
---@param path string
---@return keywork.fs.Stat? stat
---@return string? error
function M.stat(path) end
---@param path string
---@param options? {directory?: boolean}
---@return true? ok
---@return string? error
function M.remove(path, options) end
---@param old_path string
---@param new_path string
---@return true? ok
---@return string? error
function M.rename(old_path, new_path) end
return M
