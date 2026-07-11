--- High-level audio-device monitoring and control over PipeWire.
---
--- `audio.monitor()` returns a monitor whose event stream contains normalized
--- sink/source device records. It hides PipeWire interface names and property
--- keys while retaining the raw properties for applications that need them.
--- Device `volume` is on PipeWire's cubic user scale (1.0 is 100%), while
--- route-aware writes use the native linear channel volumes internally.

local json = require("keywork.json")
local loop = require("keywork.loop")
local pipewire = require("keywork.pipewire")

local audio = {}
local Monitor = {}
Monitor.__index = Monitor

local MAX_VOLUME = 10 ^ (1 / 3)

local function device_kind(properties)
  local media_class = properties["media.class"]
  if media_class == "Audio/Sink" then return "sink" end
  if media_class == "Audio/Source" then return "source" end
  return nil
end

local function observed_volume(device)
  local maximum = nil
  for _, value in ipairs(device.channel_volumes or {}) do
    if maximum == nil or value > maximum then maximum = value end
  end
  return maximum and maximum ^ (1 / 3) or nil
end

local function current_volume(device)
  return device.target_volume or observed_volume(device)
end

local function current_muted(device)
  if device.target_muted ~= nil then return device.target_muted end
  return device.muted
end

local function device_route(device)
  if not device.route_managed then return nil end
  return device.device_id, device.route_device
end

local function device_availability(monitor, device)
  local device_id, route_device = device_route(device)
  local routes = device_id and monitor.routes[device_id] or nil
  if not routes then return "unknown" end
  -- Route-managed nodes can remain registered when their hardware port is
  -- unavailable. Some devices report those routes as `no`; others omit them
  -- from the current route enumeration entirely.
  return routes[route_device] or "no"
end

local function device_record(monitor, device, event_type)
  local properties = device.properties
  local name = properties["node.name"]
  local availability = device_availability(monitor, device)
  return {
    type = event_type,
    id = device.id,
    kind = device.kind,
    name = name,
    description = properties["node.description"] or properties["node.nick"] or name,
    nick = properties["node.nick"],
    icon_name = properties["device.icon-name"] or properties["device.icon_name"],
    default = name ~= nil and monitor.defaults[device.kind] == name,
    volume = current_volume(device),
    muted = current_muted(device),
    availability = availability,
    available = availability ~= "no",
    properties = properties,
  }
end

local function publish_device(monitor, device, event_type)
  monitor.channel:push(device_record(monitor, device, event_type))
end

local function update_default(monitor, kind, name)
  local previous_name = monitor.defaults[kind]
  if previous_name == name then return end
  monitor.defaults[kind] = name
  for _, device in pairs(monitor.by_id) do
    local device_name = device.properties["node.name"]
    if device.kind == kind and (device_name == previous_name or device_name == name) then
      publish_device(monitor, device, "changed")
    end
  end
end

local function apply_metadata(monitor, event)
  if event.id ~= monitor.default_metadata_id then return end
  local kind
  if event.key == "default.audio.sink" then
    kind = "sink"
  elseif event.key == "default.audio.source" then
    kind = "source"
  else
    return
  end

  local name = nil
  if event.value then
    local decoded = json.decode(event.value)
    if type(decoded) == "table" then name = decoded.name end
  end
  update_default(monitor, kind, name)
end

local function apply_global(monitor, event)
  local properties = event.properties or {}
  if event.interface == "PipeWire:Interface:Metadata" and properties["metadata.name"] == "default" then
    monitor.default_metadata_id = event.id
    return
  end

  if event.interface ~= "PipeWire:Interface:Node" then return end
  local kind = device_kind(properties)
  if not kind then return end
  local device = { id = event.id, kind = kind, properties = properties }
  monitor.by_id[event.id] = device
  publish_device(monitor, device, "added")
end

local function apply_remove(monitor, event)
  if event.id == monitor.default_metadata_id then
    monitor.default_metadata_id = nil
    update_default(monitor, "sink", nil)
    update_default(monitor, "source", nil)
  end
  if monitor.routes[event.id] then
    monitor.routes[event.id] = nil
    for _, route_device in pairs(monitor.by_id) do
      local device_id = device_route(route_device)
      if device_id == event.id then publish_device(monitor, route_device, "changed") end
    end
  end
  local device = monitor.by_id[event.id]
  if not device then return end
  monitor.by_id[event.id] = nil
  publish_device(monitor, device, "removed")
end

local function apply_node_props(monitor, event)
  local device = monitor.by_id[event.id]
  if not device then return end
  if event.channel_volumes and #event.channel_volumes > 0 then
    device.channel_volumes = event.channel_volumes
    local volume = observed_volume(device)
    if device.target_volume and volume
        and math.abs(device.target_volume - volume) < 0.0001 then
      device.target_volume = nil
    end
  end
  if event.muted ~= nil then
    device.muted = event.muted
    if device.target_muted == event.muted then
      device.target_muted = nil
    end
  end
  if device.pending_props and device.pending_props > 0 then
    device.pending_props = device.pending_props - 1
    -- Hardware may quantize a requested volume. Once every queued write has
    -- produced a property update, the server value wins even if it does not
    -- exactly match the optimistic target.
    if device.pending_props == 0 then
      device.target_volume = nil
      device.target_muted = nil
    end
  end
  if device.target_volume == nil and device.target_muted == nil then
    device.pending_props = 0
  end
  publish_device(monitor, device, "changed")
end

local function apply_node_route(monitor, event)
  local device = monitor.by_id[event.id]
  if not device then return end
  device.route_managed = event.route_managed
  device.device_id = event.device_id
  device.route_device = event.route_device
  publish_device(monitor, device, "changed")
end

local function apply_routes_reset(monitor, event)
  monitor.routes[event.id] = {}
  for _, device in pairs(monitor.by_id) do
    local device_id = device_route(device)
    if device_id == event.id then publish_device(monitor, device, "changed") end
  end
end

local function apply_route(monitor, event)
  local routes = monitor.routes[event.id]
  if not routes then
    routes = {}
    monitor.routes[event.id] = routes
  end
  if routes[event.device] == event.availability then return end
  routes[event.device] = event.availability
  for _, device in pairs(monitor.by_id) do
    local device_id, route_device = device_route(device)
    if device_id == event.id and route_device == event.device then
      publish_device(monitor, device, "changed")
    end
  end
end

local function resolve_device(monitor, target)
  local id = type(target) == "table" and target.id or target
  if type(id) ~= "number" or id < 0 or id % 1 ~= 0 then
    error("audio device must be a device record or numeric id", 3)
  end
  return monitor.by_id[id]
end

local function finite_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

function Monitor:events()
  return self.channel:events()
end

function Monitor:devices(kind)
  if kind ~= nil and kind ~= "sink" and kind ~= "source" then
    error("audio device kind must be 'sink' or 'source'", 2)
  end
  local devices = {}
  for _, device in pairs(self.by_id) do
    if kind == nil or device.kind == kind then
      table.insert(devices, device_record(self, device, "snapshot"))
    end
  end
  table.sort(devices, function(a, b) return a.id < b.id end)
  return devices
end

function Monitor:default(kind)
  if kind ~= "sink" and kind ~= "source" then
    error("audio default kind must be 'sink' or 'source'", 2)
  end
  local name = self.defaults[kind]
  if not name then return nil end
  for _, device in pairs(self.by_id) do
    if device.kind == kind and device.properties["node.name"] == name then
      return device_record(self, device, "snapshot")
    end
  end
  return nil
end

function Monitor:sinks()
  return self:devices("sink")
end

function Monitor:sources()
  return self:devices("source")
end

function Monitor:default_sink()
  return self:default("sink")
end

function Monitor:default_source()
  return self:default("source")
end

--- Sets a device's scalar user volume, flattening any per-channel balance.
--- Values use PipeWire's cubic user scale: 1.0 is 100%.
function Monitor:set_volume(target, volume)
  if not finite_number(volume) or volume < 0 or volume > MAX_VOLUME then
    error("audio volume must be between 0 and " .. tostring(MAX_VOLUME), 2)
  end
  local device = resolve_device(self, target)
  if not device then return nil, "audio device unavailable" end
  local linear = math.min(10, volume ^ 3)
  local ok, err = self.connection:set_volume(device.id, linear)
  if not ok then return nil, err end

  device.target_volume = volume
  device.pending_props = (device.pending_props or 0) + 1
  publish_device(self, device, "changed")
  return true
end

--- Applies a relative change without losing rapid updates while PipeWire's
--- property echo is still pending. `maximum` defaults to PipeWire's limit.
function Monitor:adjust_volume(target, delta, maximum)
  if not finite_number(delta) then
    error("audio volume delta must be a finite number", 2)
  end
  if maximum ~= nil and (not finite_number(maximum) or maximum < 0 or maximum > MAX_VOLUME) then
    error("audio maximum volume is out of range", 2)
  end
  local device = resolve_device(self, target)
  if not device then return nil, "audio device unavailable" end
  local volume = current_volume(device)
  if volume == nil then return nil, "audio volume unavailable" end
  local limit = maximum or MAX_VOLUME
  return self:set_volume(device.id, math.max(0, math.min(limit, volume + delta)))
end

function Monitor:set_muted(target, muted)
  if type(muted) ~= "boolean" then
    error("audio muted state must be a boolean", 2)
  end
  local device = resolve_device(self, target)
  if not device then return nil, "audio device unavailable" end
  local ok, err = self.connection:set_mute(device.id, muted)
  if not ok then return nil, err end
  device.target_muted = muted
  device.pending_props = (device.pending_props or 0) + 1
  publish_device(self, device, "changed")
  return true
end

function Monitor:toggle_muted(target)
  local device = resolve_device(self, target)
  if not device then return nil, "audio device unavailable" end
  return self:set_muted(device.id, not (current_muted(device) == true))
end

--- Asks the session manager to make the named node the configured default.
--- The effective `default` flag changes when default.audio.* metadata follows.
function Monitor:set_default(kind, name)
  if kind ~= "sink" and kind ~= "source" then
    error("audio default kind must be 'sink' or 'source'", 2)
  end
  if type(name) ~= "string" or name == "" then
    error("audio default name must be a non-empty string", 2)
  end
  local found = false
  for _, device in pairs(self.by_id) do
    if device.kind == kind and device.properties["node.name"] == name
        and device_availability(self, device) ~= "no" then
      found = true
      break
    end
  end
  if not found then return nil, "audio device unavailable" end
  return self.connection:set_metadata(
    "default.configured.audio." .. kind,
    "Spa:String:JSON",
    json.encode({ name = name })
  )
end

function Monitor:close()
  if self.is_closed then return end
  self.is_closed = true
  self.connection:close()
  self.channel:close()
end

function Monitor:closed()
  return self.is_closed or self.connection:closed()
end

function audio.monitor()
  local connection, err = pipewire.connect()
  if not connection then return nil, err end

  local monitor = setmetatable({
    connection = connection,
    channel = loop.channel(),
    by_id = {},
    defaults = {},
    routes = {},
    default_metadata_id = nil,
    is_closed = false,
  }, Monitor)

  monitor.task = loop.spawn(function()
    for event in connection:events() do
      if event.type == "global" then
        apply_global(monitor, event)
      elseif event.type == "global_remove" then
        apply_remove(monitor, event)
      elseif event.type == "metadata" then
        apply_metadata(monitor, event)
      elseif event.type == "node_props" then
        apply_node_props(monitor, event)
      elseif event.type == "node_route" then
        apply_node_route(monitor, event)
      elseif event.type == "routes_reset" then
        apply_routes_reset(monitor, event)
      elseif event.type == "route" then
        apply_route(monitor, event)
      end
    end
    monitor.is_closed = true
    monitor.channel:close()
  end)
  return monitor
end

return audio
