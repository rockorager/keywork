--- High-level audio-device monitoring over PipeWire.
---
--- `audio.monitor()` returns a monitor whose event stream contains normalized
--- sink/source device records. It hides PipeWire interface names and property
--- keys while retaining the raw properties for applications that need them.

local json = require("keywork.json")
local loop = require("keywork.loop")
local pipewire = require("keywork.pipewire")

local audio = {}
local Monitor = {}
Monitor.__index = Monitor

local function device_kind(properties)
  local media_class = properties["media.class"]
  if media_class == "Audio/Sink" then return "sink" end
  if media_class == "Audio/Source" then return "source" end
  return nil
end

local function device_record(monitor, device, event_type)
  local properties = device.properties
  local name = properties["node.name"]
  return {
    type = event_type,
    id = device.id,
    kind = device.kind,
    name = name,
    description = properties["node.description"] or properties["node.nick"] or name,
    nick = properties["node.nick"],
    icon_name = properties["device.icon-name"] or properties["device.icon_name"],
    default = name ~= nil and monitor.defaults[device.kind] == name,
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
  local device = monitor.by_id[event.id]
  if not device then return end
  monitor.by_id[event.id] = nil
  publish_device(monitor, device, "removed")
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
      end
    end
    monitor.is_closed = true
    monitor.channel:close()
  end)
  return monitor
end

return audio
