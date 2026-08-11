---@meta keywork.xdg

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

return M
