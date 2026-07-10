--- Client-side sugar over bus:call and bus:subscribe: typed Properties
--- access, proxy objects, and property observers. Loaded with the bus
--- methods table and the dbus module as arguments; everything routes
--- through bus:call/bus:subscribe and inherits their coroutine, timeout,
--- and error semantics.

local methods, dbus = ...
local unpack = unpack or table.unpack
local maxn = table.maxn

local properties_iface = "org.freedesktop.DBus.Properties"
local bus_iface = "org.freedesktop.DBus"
local bus_path = "/org/freedesktop/DBus"

local basic_signatures = {
  string = "s",
  object_path = "o",
  boolean = "b",
  int32 = "i",
  uint32 = "u",
  double = "d",
}

-- Properties.Set requires a variant; plain scalars infer s/b/d,
-- dbus.* typed values carry their own signature, and anything else is
-- programmer misuse without an explicit signature.
local function to_variant(value, signature)
  if signature then return dbus.variant(signature, value) end
  local t = type(value)
  if t == "string" then return dbus.variant("s", value) end
  if t == "boolean" then return dbus.variant("b", value) end
  if t == "number" then return dbus.variant("d", value) end
  if t == "table" then
    local dbus_type = value.__dbus_type
    if dbus_type == "variant" then return value end
    local basic = basic_signatures[dbus_type]
    if basic then return dbus.variant(basic, value.value) end
    if dbus_type == "array" then
      return dbus.variant("a" .. value.signature, value.value)
    end
  end
  error("set_property cannot infer a signature; pass options.signature or a dbus.* typed value", 3)
end

function methods.get_property(bus, options)
  local reply, err = bus:call({
    destination = options.destination,
    path = options.path,
    interface = properties_iface,
    member = "Get",
    args = { options.interface, options.name },
    timeout_ms = options.timeout_ms,
  })
  if not reply then return nil, err end
  return reply.args[1]
end

function methods.set_property(bus, options)
  local value = to_variant(options.value, options.signature)
  local reply, err = bus:call({
    destination = options.destination,
    path = options.path,
    interface = properties_iface,
    member = "Set",
    args = { options.interface, options.name, value },
    timeout_ms = options.timeout_ms,
  })
  if not reply then return nil, err end
  return true
end

-- Unknown keys on a proxy become method-call stubs, memoized on first
-- access. The bus/destination/path/interface fields are reserved.
function methods.proxy(bus, destination, path, interface, options)
  assert(type(destination) == "string", "proxy requires a destination string")
  assert(type(path) == "string", "proxy requires a path string")
  assert(type(interface) == "string", "proxy requires an interface string")
  local timeout_ms = options and options.timeout_ms
  local proxy = {
    bus = bus,
    destination = destination,
    path = path,
    interface = interface,
  }
  return setmetatable(proxy, {
    __index = function(self, member)
      local call = function(_, ...)
        local reply, err = bus:call({
          destination = destination,
          path = path,
          interface = interface,
          member = member,
          args = { ... },
          timeout_ms = timeout_ms,
        })
        if not reply then return nil, err end
        return unpack(reply.args, 1, maxn(reply.args))
      end
      rawset(self, member, call)
      return call
    end,
  })
end

local function shallow_copy(source)
  local copy = {}
  for key, value in pairs(source) do
    copy[key] = value
  end
  return copy
end

--- Observes one interface of one remote object: an initial GetAll snapshot
--- followed by PropertiesChanged deltas, with owner tracking so a daemon
--- restart resyncs and a vanished owner reports unavailable (and a later
--- start recovers). Events arrive on obs:changes() as
--- { props = <merged snapshot>, changed = <delta>, available = <bool> }.
--- Resources are owned by the ambient task; call obs:cancel() otherwise.
function methods.observe(bus, options)
  assert(type(options.destination) == "string", "observe requires a destination string")
  assert(type(options.path) == "string", "observe requires a path string")
  assert(type(options.interface) == "string", "observe requires an interface string")
  local loop = require("keywork.loop")
  local destination = options.destination
  local path = options.path
  local interface = options.interface
  local timeout_ms = options.timeout_ms

  local channel = loop.channel()

  -- Subscribe before the first GetAll so no change escapes the window
  -- between snapshot and stream.
  local props_sub = bus:subscribe({
    path = path,
    interface = properties_iface,
    member = "PropertiesChanged",
  })
  local owner_sub = bus:subscribe({
    sender = bus_iface,
    path = bus_path,
    interface = bus_iface,
    member = "NameOwnerChanged",
  })

  local props = {}
  -- Unique-name owner of the destination; nil while unavailable. Signal
  -- senders are unique names, so this doubles as the sender filter (the
  -- destination may be a well-known name that never appears as a sender).
  local owner = nil
  local synced = false

  local function emit(changed)
    channel:push({
      props = shallow_copy(props),
      changed = changed,
      available = owner ~= nil,
    })
  end

  local function resync()
    local reply = bus:call({
      destination = destination,
      path = path,
      interface = properties_iface,
      member = "GetAll",
      args = { interface },
      timeout_ms = timeout_ms,
    })
    if not reply then
      -- Owner present but unreadable; report unavailable rather than stale.
      owner = nil
      props = {}
      synced = true
      emit({})
      return
    end
    props = (reply.args or {})[1] or {}
    synced = true
    emit(shallow_copy(props))
  end

  -- Merge property deltas. Deltas queued while a GetAll is in flight merge
  -- before its reply overwrites props; the reply is ordered after them on
  -- the bus, so the overwrite wins correctly. Emits only once synced.
  loop.spawn(function()
    for signal in props_sub:events() do
      if signal.sender == owner and (signal.args or {})[1] == interface then
        local changed = signal.args[2] or {}
        local invalidated = signal.args[3]
        for name, value in pairs(changed) do
          props[name] = value
        end
        if synced then
          if invalidated and #invalidated > 0 then
            -- Invalidated properties carry no value in the signal; the
            -- only honest recovery is a fresh snapshot.
            resync()
          else
            emit(changed)
          end
        end
      end
    end
  end)

  -- Track the destination's owner. The initial snapshot rides here so
  -- observe itself never parks.
  loop.spawn(function()
    local reply = bus:call({
      destination = bus_iface,
      path = bus_path,
      interface = bus_iface,
      member = "GetNameOwner",
      args = { destination },
      timeout_ms = timeout_ms,
    })
    owner = reply and (reply.args or {})[1] or nil
    if owner then
      resync()
    else
      synced = true
      emit({})
    end
    for signal in owner_sub:events() do
      local args = signal.args or {}
      if args[1] == destination then
        local new_owner = args[3]
        if new_owner == "" then new_owner = nil end
        owner = new_owner
        if owner then
          -- Daemon restarted (or ownership transferred): full resync
          -- against the new owner.
          resync()
        else
          props = {}
          emit({})
        end
      end
    end
  end)

  local obs = {
    bus = bus,
    destination = destination,
    path = path,
    interface = interface,
  }

  function obs:changes()
    return channel:events()
  end

  function obs:cancel()
    props_sub:cancel()
    owner_sub:cancel()
    channel:close()
  end

  return obs
end
