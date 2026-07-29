---@meta keywork.audio

---@alias keywork.audio.DeviceKind 'sink'|'source'
---@alias keywork.audio.EventType 'added'|'changed'|'removed'|'snapshot'
---@alias keywork.audio.Availability 'unknown'|'no'|'yes'

---@class keywork.audio.MonitorOptions
---@field realtime? boolean

---@class keywork.audio.Device
---@field type         keywork.audio.EventType
---@field id           integer
---@field kind         keywork.audio.DeviceKind
---@field name?        string
---@field description? string
---@field nick?        string
---@field icon_name?   string
---@field default      boolean
---@field volume?      number                     Cubic user volume; 1.0 is 100%.
---@field muted?       boolean
---@field availability keywork.audio.Availability
---@field available    boolean
---@field port_type?   string
---@field bus?         string
---@field properties   table<string, string>

---@class keywork.audio.Monitor
local Monitor = {}

---@return fun(): keywork.audio.Device?
function Monitor:events() end

---@param kind? keywork.audio.DeviceKind
---@return keywork.audio.Device[]
function Monitor:devices(kind) end

---@param kind keywork.audio.DeviceKind
---@return keywork.audio.Device?
function Monitor:default(kind) end

---@return keywork.audio.Device[]
function Monitor:sinks() end

---@return keywork.audio.Device[]
function Monitor:sources() end

---@return keywork.audio.Device?
function Monitor:default_sink() end

---@return keywork.audio.Device?
function Monitor:default_source() end

---@param target keywork.audio.Device | integer
---@param volume number                         Cubic user volume; 1.0 is 100%.
---@return true? ok
---@return string? error
function Monitor:set_volume(target, volume) end

---@param target   keywork.audio.Device | integer
---@param delta    number
---@param maximum? number
---@return true? ok
---@return string? error
function Monitor:adjust_volume(target, delta, maximum) end

---@param target keywork.audio.Device | integer
---@param muted  boolean
---@return true? ok
---@return string? error
function Monitor:set_muted(target, muted) end

---@param target keywork.audio.Device | integer
---@return true? ok
---@return string? error
function Monitor:toggle_muted(target) end

---@param kind keywork.audio.DeviceKind
---@param name string                   Node name from the device record.
---@return true? ok
---@return string? error
function Monitor:set_default(kind, name) end

function Monitor:close() end

---@return boolean
function Monitor:closed() end

local M = {}

---@param options? keywork.audio.MonitorOptions
---@return keywork.audio.Monitor? monitor
---@return string? error
function M.monitor(options) end

return M
