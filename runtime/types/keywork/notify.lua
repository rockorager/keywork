---@meta keywork.notify

---@alias keywork.notify.Urgency 'low'|'normal'|'critical'
---@alias keywork.notify.CloseReason 'expired'|'dismissed'|'closed'|'undefined'

---@class keywork.notify.Action
---@field id    string
---@field label string

---@class keywork.notify.SendOptions
---@field summary      string
---@field app_name?    string
---@field replaces_id? integer
---@field icon?        string
---@field body?        string
---@field actions?     keywork.notify.Action[]
---@field urgency?     keywork.notify.Urgency
---@field hints?       table<string, keywork.dbus.TypedValue<any>>
---@field timeout_ms?  integer
---@field on_action?   fun(action_id: string)
---@field on_close?    fun(reason: keywork.notify.CloseReason)

---@class keywork.notify.ServerInfo
---@field name         string
---@field vendor       string
---@field version      string
---@field spec_version string

local M = {}

--- Sends a notification. Must be called from a loop task.
---@param options keywork.notify.SendOptions
---@return integer? id
---@return string? error
function M.send(options) end

--- Closes a notification. Must be called from a loop task.
---@param id integer
---@return true? ok
---@return string? error
function M.close(id) end

--- Reads server information. Must be called from a loop task.
---@return keywork.notify.ServerInfo? info
---@return string? error
function M.server_info() end

return M
