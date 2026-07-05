local ui = require("ui")
local keywork = require("keywork")
local bit = require("bit")

local has_unix_socket, unix_socket = pcall(require, "socket.unix")

local EPOLLIN = 1
local EPOLLERR = 8
local EPOLLHUP = 16
local IPC_COMMAND = 0
local IPC_GET_WORKSPACES = 1
local IPC_SUBSCRIBE = 2

local function bar_colors(theme)
  local scheme = theme.colors
  return {
    background = scheme.surface,
    surface = scheme.surface_variant,
    foreground = scheme.on_surface,
    muted = scheme.on_surface_variant,
    active = scheme.primary,
    on_active = scheme.on_primary,
    error = scheme.error,
    on_error = scheme.on_error,
    success = 0xff9ece6a,
    warning = 0xffe0af68,
    accent = scheme.primary,
  }
end

local function trim(value)
  local trimmed = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return trimmed
end

local function le32(value)
  return string.char(
    bit.band(value, 0xff),
    bit.band(bit.rshift(value, 8), 0xff),
    bit.band(bit.rshift(value, 16), 0xff),
    bit.band(bit.rshift(value, 24), 0xff)
  )
end

local function read_le32(value, offset)
  local b1, b2, b3, b4 = value:byte(offset, offset + 3)
  if not b4 then
    return nil
  end
  return b1 + bit.lshift(b2, 8) + bit.lshift(b3, 16) + bit.lshift(b4, 24)
end

local function write_all(socket, data)
  local sent = 0
  while sent < #data do
    local index, err, partial = socket:send(data, sent + 1)
    if index then
      sent = index
    elseif err == "timeout" and partial and partial > sent then
      sent = partial
    else
      return false
    end
  end
  return true
end

local function sway_send(client, message_type, payload)
  payload = payload or ""
  return write_all(client.socket, "i3-ipc" .. le32(#payload) .. le32(message_type) .. payload)
end

local function json_string(value)
  return tostring(value):gsub('\\', '\\\\'):gsub('"', '\\"')
end

local function parse_workspaces(payload)
  local workspaces = {}
  for object in payload:gmatch("%b{}") do
    local name = object:match('"name"%s*:%s*"(.-)"')
    if name then
      table.insert(workspaces, {
        name = name,
        focused = object:match('"focused"%s*:%s*true') ~= nil,
        urgent = object:match('"urgent"%s*:%s*true') ~= nil,
      })
    end
  end
  return workspaces
end

local function handle_sway_frame(client, message_type, payload)
  if message_type == IPC_GET_WORKSPACES then
    client.workspaces = parse_workspaces(payload)
    return true
  end

  if bit.band(message_type, 0x80000000) ~= 0 then
    sway_send(client, IPC_GET_WORKSPACES, "")
  end
  return false
end

local function drain_sway(client)
  local changed = false
  while true do
    local data, err, partial = client.socket:receive(4096)
    local chunk = data or partial
    if chunk and #chunk > 0 then
      client.buffer = client.buffer .. chunk
    end
    if data then
      -- A full 4096-byte read may have left more data queued; keep draining.
    elseif err == "timeout" then
      break
    else
      if err == "closed" then
        client.connected = false
      end
      return changed
    end
  end

  while #client.buffer >= 14 do
    if client.buffer:sub(1, 6) ~= "i3-ipc" then
      client.connected = false
      return changed
    end
    local length = read_le32(client.buffer, 7)
    local message_type = read_le32(client.buffer, 11)
    if not length or not message_type or #client.buffer < 14 + length then
      break
    end
    local payload = client.buffer:sub(15, 14 + length)
    client.buffer = client.buffer:sub(15 + length)
    changed = handle_sway_frame(client, message_type, payload) or changed
  end
  return changed
end

local function connect_sway(on_change)
  local path = os.getenv("SWAYSOCK")
  if not has_unix_socket or not path or path == "" then
    return nil
  end

  local socket = unix_socket()
  if not socket then
    return nil
  end

  if not socket:connect(path) then
    socket:close()
    return nil
  end
  socket:settimeout(0)

  local client = {
    socket = socket,
    fd = socket:getfd(),
    buffer = "",
    workspaces = {},
    connected = true,
  }

  client.watch = keywork.loop.fd(client.fd, { read = true }, function(_, events)
    if bit.band(events, bit.bor(EPOLLERR, EPOLLHUP)) ~= 0 then
      client.connected = false
    end
    if bit.band(events, EPOLLIN) ~= 0 then
      if drain_sway(client) then
        on_change()
      end
    end
  end)
  sway_send(client, IPC_GET_WORKSPACES, "")
  sway_send(client, IPC_SUBSCRIBE, '["workspace"]')
  return client
end

local function capture(argv, callback)
  local stdout = {}
  local stderr = {}
  return keywork.loop.spawn({
    argv = argv,
    stdout = "pipe",
    stderr = "pipe",
  }, {
    stdout = function(chunk)
      table.insert(stdout, chunk)
    end,
    stderr = function(chunk)
      table.insert(stderr, chunk)
    end,
    exit = function(result)
      result.stdout = table.concat(stdout)
      result.stderr = table.concat(stderr)
      callback(result)
    end,
  })
end

local function label(value, palette, color)
  return ui.label(value, { color = color or palette.foreground })
end

local function status_pill(palette, id, icon_name, text, color, options)
  options = options or {}
  local child = ui.icon_theme({ color = color, size = options.icon_size or 16 },
    ui.default_text_style({ color = color },
      ui.icon_label(icon_name, text, { size = options.icon_size or 16 })
    )
  )
  return ui.chip({
    id = id,
    child = child,
    background = palette.surface,
    radius = 10,
    min_height = 30,
    align = "center",
    padding = { x = 7 },
    on_tap = function()
      print("clicked " .. id)
    end,
  })
end

local function workspaces(palette, sway)
  local items = {}
  for _, workspace in ipairs(sway.workspaces or {}) do
    local name = workspace.name
    local fg = palette.muted
    local bg = palette.background
    if workspace.urgent then
      fg = palette.on_error
      bg = palette.error
    elseif workspace.focused then
      fg = palette.on_active
      bg = palette.active
    end
    table.insert(items, ui.chip({
      id = "workspace-" .. name,
      child = ui.default_text_style({ color = fg }, ui.label(name)),
      background = bg,
      radius = 9,
      min_height = 30,
      align = "center",
      padding = { x = 12 },
      on_tap_down = function()
        if sway.connected then
          sway_send(sway, IPC_COMMAND, 'workspace "' .. json_string(name) .. '"')
        end
      end,
    }))
  end

  if #items == 0 then
    table.insert(items, label(sway.connected and "loading sway" or "no sway", palette, palette.muted))
  end
  return ui.row({ spacing = 4, children = items })
end

local function volume_status_from_output(palette, output)
  local raw = tonumber(output:match("Volume:%s*([%d%.]+)")) or 0
  local percent = math.floor(raw * 100 + 0.5)
  local muted = output:find("MUTED", 1, true) ~= nil
  local name = "audio-volume-high"
  local color = palette.accent
  if muted or percent <= 0 then
    name = "audio-volume-muted"
    color = palette.muted
  elseif percent < 34 then
    name = "audio-volume-low"
  elseif percent < 67 then
    name = "audio-volume-medium"
  end
  return status_pill(palette, "volume", name, nil, color)
end

local function network_status_from_output(palette, output)
  local operstate, essid, quality = output:match("^([^\n]*)\n([^\n]*)\n([^\n]*)")
  operstate = trim(operstate or "down")
  essid = trim(essid or "")
  local percent = math.max(0, math.min(100, tonumber(quality) or 0))
  local name = "network-wireless-offline"
  local color = palette.error
  if operstate == "up" then
    color = palette.active
    if percent >= 80 then
      name = "network-wireless-signal-excellent"
    elseif percent >= 60 then
      name = "network-wireless-signal-good"
    elseif percent >= 40 then
      name = "network-wireless-signal-ok"
    elseif percent >= 20 then
      name = "network-wireless-signal-weak"
    else
      name = "network-wireless-signal-none"
    end
  end
  return status_pill(palette, "network", name, nil, color)
end

local function battery_status_from_output(palette, output)
  local capacity_text, status = output:match("^([^\n]*)\n([^\n]*)")
  if not capacity_text then
    return status_pill(palette, "battery", "battery-level-0", "", palette.muted, { icon_size = 14 })
  end
  local capacity = tonumber(trim(capacity_text)) or 0
  status = trim(status or "Unknown")
  local level = math.floor(capacity / 10) * 10
  if capacity > 0 and level == 0 then
    level = 10
  end
  if capacity >= 95 then
    level = 100
  end

  local name = "battery-level-" .. tostring(level)
  if status == "Charging" then
    if level == 100 then
      name = "battery-full-charging"
    else
      name = name .. "-charging"
    end
  elseif status == "Full" then
    name = "battery-level-100-charged"
  end

  local color = palette.success
  if status ~= "Charging" and status ~= "Full" then
    if capacity <= 15 then
      color = palette.error
    elseif capacity <= 30 then
      color = palette.warning
    end
  end
  return status_pill(palette, "battery", name, tostring(capacity) .. "%", color, { icon_size = 14 })
end

local StatusItems = ui.stateful({
  init = function(self)
    local palette = self.props.colors
    self.volume = status_pill(palette, "volume", "audio-volume-muted", nil, palette.muted)
    self.network = status_pill(palette, "network", "network-wireless-offline", nil, palette.error)
    self.battery = status_pill(palette, "battery", "battery-level-0", "", palette.muted, { icon_size = 14 })
    self.time = os.date("%a %b %d  %I:%M %p")
    self:update_status()
    self.timer = keywork.loop.timer({ interval = 1.0 }, function()
      self:set_state(function(state)
        state:update_status()
      end)
    end)
  end,

  dispose = function(self)
    if self.timer then
      self.timer:cancel()
    end
    if self.volume_proc then
      self.volume_proc:cancel()
    end
    if self.network_proc then
      self.network_proc:cancel()
    end
    if self.battery_proc then
      self.battery_proc:cancel()
    end
  end,

  update_status = function(self)
    local palette = self.props.colors
    self.colors = palette
    self.time = os.date("%a %b %d  %I:%M %p")

    if not self.volume_proc then
      self.volume_proc = capture({ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }, function(result)
        self.volume_proc = nil
        if result.ok then
          self:set_state(function(state)
            state.volume = volume_status_from_output(state.props.colors, result.stdout)
          end)
        end
      end)
    end

    if not self.network_proc then
      self.network_proc = capture({ "sh", "-c", [[
iface=$(ls /sys/class/net 2>/dev/null | grep -E '^wl|^wlan' | head -n1)
if [ -z "$iface" ]; then
  printf 'down\n\n0\n'
  exit 0
fi
cat "/sys/class/net/$iface/operstate" 2>/dev/null
iwgetid -r 2>/dev/null
awk -v iface="$iface:" '$1 == iface { printf "%d\n", ($3 * 100 / 70 + 0.5) }' /proc/net/wireless 2>/dev/null
]] }, function(result)
        self.network_proc = nil
        if result.ok then
          self:set_state(function(state)
            state.network = network_status_from_output(state.props.colors, result.stdout)
          end)
        end
      end)
    end

    if not self.battery_proc then
      self.battery_proc = capture({ "sh", "-c", [[
battery=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -n1)
if [ -n "$battery" ]; then
  cat "$battery/capacity" 2>/dev/null
  cat "$battery/status" 2>/dev/null
fi
]] }, function(result)
        self.battery_proc = nil
        if result.ok then
          self:set_state(function(state)
            state.battery = battery_status_from_output(state.props.colors, result.stdout)
          end)
        end
      end)
    end
  end,

  update = function(self)
    if self.colors ~= self.props.colors then
      self:update_status()
    end
  end,

  build = function(self, context)
    local palette = self.props.colors
    return ui.row({
      spacing = 8,
      align = "center",
      children = {
        self.volume,
        self.network,
        self.battery,
        label(self.time, palette),
      },
    })
  end,
})

local SwayWorkspaces = ui.stateful({
  init = function(self)
    self.sway = connect_sway(function()
      self:set_state()
    end) or { fd = -1, buffer = "", workspaces = {}, connected = false }
  end,

  dispose = function(self)
    if self.sway.watch then
      self.sway.watch:cancel()
    end
    if self.sway.socket then
      self.sway.socket:close()
    end
  end,

  build = function(self)
    return workspaces(self.props.colors, self.sway)
  end,
})

local App = ui.stateful({
  build = function(self, context)
    local theme = context.theme
    local palette = bar_colors(theme)
    local left = ui.row({
      spacing = 10,
      align = "center",
      children = {
        SwayWorkspaces({ key = "sway-workspaces", colors = palette }),
        ui.row({
          spacing = 6,
          align = "center",
          children = {
            ui.svg_icon("examples/lua/icons/bolt.svg", 16, palette.accent),
            label("Keywork", palette),
          },
        }),
      },
    })

    return ui.theme(theme, ui.container({ background = palette.background, padding = { all = 4 } },
      ui.row({
        spacing = 12,
        align = "center",
        children = {
          left,
          ui.spacer(),
          StatusItems({ key = "status", colors = palette }),
        },
      })
    ))
  end,
})

return App({ key = "app" })
