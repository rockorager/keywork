---@meta keywork.stream

local M = {}

--- Converts a chunk iterator into an iterator of lines without newlines.
---@generic S
---@param next_fn fun(state: S): string?
---@param state?  S
---@return fun(): string?
function M.lines(next_fn, state) end

return M
