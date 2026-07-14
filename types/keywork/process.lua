---@meta keywork.process

---@alias keywork.process.Stdio 'pipe' | 'ignore'

---@class keywork.process.SpawnOptions
---@field argv    string[]
---@field env?    table<string, string> Entries are merged over the inherited environment.
---@field stdin?  keywork.process.Stdio
---@field stdout? keywork.process.Stdio
---@field stderr? keywork.process.Stdio

---@class keywork.process.Result
---@field code?   integer Exit code when the process exited normally.
---@field signal? integer Signal number when the process was killed by a signal.
---@field ok      boolean
---@field stdout? string  Not populated by `wait`; available when attached by a collecting caller.
---@field stderr? string  Not populated by `wait`; available when attached by a collecting caller.

---@class keywork.process.CaptureResult: keywork.process.Result
---@field stdout string
---@field stderr string

---@class keywork.process.CaptureOptions
---@field argv string[] Other spawn options are intentionally unsupported by `capture`.

---@class keywork.process.Process
local Process = {}

---@return fun(): string?
function Process:stdout() end

---@return fun(): string?
function Process:stderr() end

---@param data string
---@return true? ok
---@return string? error
function Process:write(data) end

function Process:close_stdin() end

---@return keywork.process.Result?
function Process:wait() end

function Process:cancel() end

---@return boolean
function Process:canceled() end

local M = {}

---@param options keywork.process.SpawnOptions
---@return keywork.process.Process? process
---@return string? error
function M.spawn(options) end

--- Runs a command to completion. Must be called from a loop task.
---@overload fun(spec: string[]): keywork.process.CaptureResult? result, string? error
---@param spec keywork.process.CaptureOptions
---@return keywork.process.CaptureResult? result
---@return string? error
function M.capture(spec) end

return M
