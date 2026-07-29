---@meta

---@alias shell.wayland.EventState 'idled' | 'resumed'

---@class shell.wayland.Event
---@field id    number
---@field state shell.wayland.EventState

---@class shell.wayland.Workspace
---@field id           number
---@field name         string
---@field active       boolean
---@field urgent       boolean
---@field hidden       boolean
---@field can_activate boolean
---@field outputs      string[]

---@class shell.wayland.Client
local Client = {}

---@return integer?
function Client:fd() end

---@param timeout_ms integer
---@return number? id
---@return string? error
function Client:watch(timeout_ms) end

---@param on boolean
---@return boolean? ok
---@return string? error
function Client:set_outputs_power(on) end

---@return shell.wayland.Event[]? events
---@return string? error
function Client:dispatch() end

function Client:close() end

---@class shell.wayland.WorkspaceClient
local WorkspaceClient = {}

---@return integer?
function WorkspaceClient:fd() end

---@return shell.wayland.Workspace[]? workspaces
---@return string? error
function WorkspaceClient:snapshot() end

---@return shell.wayland.Workspace[]? workspaces
---@return string? error
function WorkspaceClient:dispatch() end

---@param id number
---@return boolean? ok
---@return string? error
function WorkspaceClient:activate(id) end

function WorkspaceClient:close() end

local M = {}

---@return shell.wayland.Client? client
---@return string? error
function M.connect() end

---@return shell.wayland.WorkspaceClient? client
---@return string? error
function M.connect_workspaces() end

return M
