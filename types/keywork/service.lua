---@meta keywork.service

---@class keywork.service.ServiceBase<T>
---@field name        string
---@field state?      T
---@field subscribers table<table, fun(value: T)>
---@field count       integer
local ServiceBase = {}

---@param value T
function ServiceBase:publish(value) end

--- Subscribes for the lifetime of `scope` and returns the latest snapshot.
---@param scope     keywork.loop.Scope
---@param on_change fun(value: T)
---@return T?
function ServiceBase:use(scope, on_change) end

---@class keywork.service.Service<T>: keywork.service.ServiceBase<T>
---@field start  fun(self: keywork.service.ServiceStartContext<T>)
---@field scope? keywork.loop.Scope
---@field task?  keywork.loop.Task

--- The service passed to `start`. Its lifecycle scope has been created before
--- the callback is invoked; the stored service may be idle and have no scope.
---@class keywork.service.ServiceStartContext<T>: keywork.service.ServiceBase<T>
---@field start fun(self: keywork.service.ServiceStartContext<T>)
---@field scope keywork.loop.Scope
---@field task? keywork.loop.Task

local M = {}

--- EmmyLua Analyzer 0.24 cannot infer `T` solely from `self:publish` calls in
--- `start`. Annotate the returned `Service<T>` when snapshot checking is needed.
---@generic T
---@param name  string
---@param start fun(self: keywork.service.ServiceStartContext<T>)
---@return keywork.service.Service<T>
function M.define(name, start) end

return M
