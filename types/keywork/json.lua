---@meta keywork.json

---@class keywork.json.Null

---@alias keywork.json.Value nil | boolean | number | string | keywork.json.Null | keywork.json.Value[] | table<string, keywork.json.Value>

local M = {}

--- Raises when the value cannot be represented as JSON.
---@param value keywork.json.Value
---@return string
function M.encode(value) end

---@param input string
---@return keywork.json.Value? value
---@return string? error
function M.decode(input) end

--- Marks a table as a JSON array, preserving empty arrays during encoding.
---@generic T: table
---@param value? T
---@return T
function M.array(value) end

---@type keywork.json.Null
M.null = nil

return M
