---@meta keywork.loop

---@alias keywork.loop.TaskStatus 'running'|'completed'|'failed'|'canceled'
---@alias keywork.loop.TaskFunction fun(...: any): ...

---@class keywork.loop.Task
local Task = {}

---@return keywork.loop.TaskStatus
function Task:status() end

--- Waits for the task to settle. Must be called from a coroutine while running.
---@return keywork.loop.TaskStatus
function Task:join() end

function Task:cancel() end

---@class keywork.loop.Scope
local Scope = {}

---@param fn  keywork.loop.TaskFunction
---@param any
---@return keywork.loop.Task
function Scope:spawn(fn, ...) end

function Scope:cancel() end

---@return boolean
function Scope:canceled() end

---@param callback fun()
function Scope:on_cancel(callback) end

---@class keywork.loop.DelayTimerOptions
---@field delay     number Initial delay in seconds.
---@field interval? number Repeating interval in seconds.
---@field wall?     false

---@class keywork.loop.IntervalTimerOptions
---@field interval number Repeating interval in seconds; also the initial delay when `delay` is absent.
---@field delay?   number Initial delay in seconds.
---@field wall?    false

---@class keywork.loop.WallTimerOptions
---@field interval number Repeating interval in seconds.
---@field wall     true   Align expirations to wall-clock boundaries.

---@alias keywork.loop.TimerOptions keywork.loop.DelayTimerOptions | keywork.loop.IntervalTimerOptions | keywork.loop.WallTimerOptions

---@class keywork.loop.Timer
local Timer = {}

---@return integer? expirations
function Timer:next() end

---@return fun(): integer?
function Timer:ticks() end

function Timer:cancel() end

---@return boolean
function Timer:canceled() end

---@class keywork.loop.FdOptions
---@field read?  boolean
---@field write? boolean

---@class keywork.loop.FdEvent
---@field read  boolean
---@field write boolean
---@field err   boolean
---@field hup   boolean

---@class keywork.loop.FdWatch
local FdWatch = {}

---@return keywork.loop.FdEvent?
function FdWatch:next() end

---@return fun(): keywork.loop.FdEvent?
function FdWatch:events() end

function FdWatch:cancel() end

---@return boolean
function FdWatch:canceled() end

---@class keywork.loop.FsEvent
---@field path        string
---@field name?       string
---@field mask        integer
---@field change      boolean
---@field rename      boolean
---@field delete_self boolean
---@field move_self   boolean

---@class keywork.loop.FsWatch
local FsWatch = {}

---@return keywork.loop.FsEvent?
function FsWatch:next() end

---@return fun(): keywork.loop.FsEvent?
function FsWatch:events() end

function FsWatch:cancel() end

---@return boolean
function FsWatch:canceled() end

---@class keywork.loop.Channel<T>
local Channel = {}

---@param value T
function Channel:push(value) end

---@return T?
function Channel:next() end

---@return fun(): T?
function Channel:events() end

--- Ends the stream after queued values have been read.
function Channel:close() end

--- Cancels the stream and discards queued values.
function Channel:cancel() end

---@return boolean
function Channel:canceled() end

local M = {}

---@param options keywork.loop.TimerOptions
---@return keywork.loop.Timer
function M.timer(options) end

---@param fd       integer
---@param options? keywork.loop.FdOptions
---@return keywork.loop.FdWatch
function M.fd(fd, options) end

---@param path string | { path: string }
---@return keywork.loop.FsWatch? watch
---@return string? error
function M.fs_event(path) end

---@param fn  keywork.loop.TaskFunction
---@param any
---@return keywork.loop.Task
function M.spawn(fn, ...) end

---@return keywork.loop.Scope
function M.scope() end

--- Parks the current coroutine for at least `milliseconds`.
---@param milliseconds number
function M.sleep(milliseconds) end

---@generic T
---@return keywork.loop.Channel<T>
function M.channel() end

return M
