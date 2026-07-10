--- App-scoped shared services: refcounted background monitors.
---
--- A service is defined once at module level and started lazily when its
--- first subscriber arrives. The service body runs as a task in its own
--- scope, so every async resource it creates (buses, sockets, processes,
--- timers, child tasks) is owned by that scope. When the last subscriber
--- releases -- typically because its widget was disposed -- the scope is
--- canceled and everything the service created is torn down.
---
--- The registry survives script reloads via the module cache, but reload
--- cancels every scope, so a stale entry is detected (dead scope handle)
--- and reset on the next use.

local loop = require("keywork.loop")

local registry = {}

local Service = {}
Service.__index = Service

local function reset(svc)
  svc.scope = nil
  svc.task = nil
  svc.state = nil
  svc.subscribers = {}
  svc.count = 0
end

local function dead(svc)
  return svc.scope == nil or svc.scope:canceled()
end

--- Stores the current snapshot and notifies every subscriber. Called by
--- the service body; also callable from outside for testing or manual
--- refresh.
function Service:publish(value)
  self.state = value
  for _, on_change in pairs(self.subscribers) do
    on_change(value)
  end
end

--- Subscribes `on_change` for the lifetime of `scope` and returns the
--- current snapshot (nil until the service first publishes). The first
--- subscriber starts the service; scope cancellation releases the
--- subscription, and the last release stops the service. A service whose
--- body settled (finished or failed) is restarted by the next use.
function Service:use(scope, on_change)
  if dead(self) then
    reset(self)
    self.scope = loop.scope()
    self.task = self.scope:spawn(self.start, self)
  elseif self.task and self.task:status() ~= "running" then
    self.task = self.scope:spawn(self.start, self)
  end

  local key = {}
  self.subscribers[key] = on_change
  self.count = self.count + 1

  local released = false
  scope:on_cancel(function()
    if released then
      return
    end
    released = true
    self.subscribers[key] = nil
    self.count = self.count - 1
    if self.count == 0 and self.scope then
      self.scope:cancel()
    end
  end)

  return self.state
end

local service = {}

--- Registers (or re-registers) a service. Redefining an existing name
--- updates the start function but keeps the entry, so module reloads
--- don't orphan running services.
function service.define(name, start)
  assert(type(name) == "string", "service name must be a string")
  assert(type(start) == "function", "service start must be a function")
  local existing = registry[name]
  if existing then
    existing.start = start
    return existing
  end
  local svc = setmetatable({ name = name, start = start }, Service)
  reset(svc)
  registry[name] = svc
  return svc
end

return service
